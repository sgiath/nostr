defmodule Nostr.Relay.Pipeline.Engine do
  @moduledoc """
  Executes websocket message handling through a configurable stage pipeline.

  The engine owns the request lifecycle:

  1. build request context with current connection state
  2. run each stage in order
  3. finalize results into a `WebSock` response shape

  Stage sequence can be overridden via the `:stages` option, which defaults to:

  - `ProtocolValidator`
  - `AuthEnforcer`
  - `MessageValidator`
  - `EventValidator`
  - `RelayPolicyValidator`
  - `StorePolicy`
  - `MessageHandler`

  Stage contract:

  - `{:ok, context}` to continue
  - `{:error, reason, context}` to halt and return a request notice

  Invalid payloads or malformed stage outputs are converted into protocol notices.
  """

  alias Nostr.Message
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Web.ConnectionState
  require Logger

  @default_stages [
    Nostr.Relay.Pipeline.Stages.ProtocolValidator,
    Nostr.Relay.Pipeline.Stages.AuthEnforcer,
    Nostr.Relay.Pipeline.Stages.MessageValidator,
    Nostr.Relay.Pipeline.Stages.EventValidator,
    Nostr.Relay.Pipeline.Stages.RelayPolicyValidator,
    Nostr.Relay.Pipeline.Stages.StorePolicy,
    Nostr.Relay.Pipeline.Stages.MessageHandler
  ]

  @spec run(binary(), ConnectionState.t(), keyword()) :: WebSock.handle_result()
  @doc "Run a raw websocket frame through the configured pipeline stages."
  def run(raw_frame, %ConnectionState{} = state) do
    run(raw_frame, state, [])
  end

  def run(raw_frame, %ConnectionState{} = state, options)
      when is_binary(raw_frame) and is_list(options) do
    context = Context.new(raw_frame, ConnectionState.inc_messages(state))

    log_pipeline_start(context)

    stages_from_options(options)
    |> run_stages(context, options)
    |> finalize()
  end

  def run(_raw_frame, %ConnectionState{} = state, _options) do
    Logger.warning("[pipeline] step=transport status=invalid payload")

    {:push, [{:text, Message.notice("invalid message format") |> Message.serialize()}], state}
  end

  defp run_stages(stages, context, options) when is_list(stages) and is_list(options) do
    stages
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, context}, fn {stage, step}, {:ok, previous_context} ->
      stage_name = stage_name(stage)
      step_name = "#{step}:#{stage_name}"

      Logger.debug("[pipeline] step=#{step_name} status=starting")

      stage_result = invoke_stage(stage, previous_context, options)

      case stage_result do
        {:ok, %Context{} = updated_context} ->
          Logger.debug(
            "[pipeline] step=#{step_name} status=ok message_count=#{updated_context.connection_state.messages}"
          )

          {:cont, {:ok, updated_context}}

        {:error, _reason, %Context{} = _updated_context} ->
          log_stage_error(step_name, stage_result)

          {:halt, stage_result}

        _other ->
          log_stage_error(step_name, {:error, :invalid_stage_result, previous_context})

          {:halt, {:error, :invalid_stage_result, previous_context}}
      end
    end)
  end

  defp stages_from_options(options) do
    Keyword.get(options, :stages, @default_stages)
  end

  defp invoke_stage(stage, context, options) when is_atom(stage) and is_list(options) do
    stage.call(context, options)
  end

  defp invoke_stage(_stage, context, _options), do: {:error, :invalid_stage_result, context}

  defp finalize({:ok, %Context{} = context}), do: finalize_ok(context)

  defp finalize({:error, reason, %Context{} = context}) do
    Logger.debug("[pipeline] step=finalize status=error reason=#{inspect(reason)}")
    finalize_error(Context.set_error(context, reason))
  end

  defp finalize(_unexpected) do
    Logger.debug("[pipeline] step=finalize status=error reason=:invalid_stage_result")
    finalize_error(%Context{error: :invalid_stage_result})
  end

  # When a stage queues response frames (e.g. EventValidator adding an OK rejection),
  # push those instead of generating a generic NOTICE.
  defp finalize_error(%Context{frames: frames, connection_state: state})
       when is_list(frames) and frames != [] do
    Logger.debug("[pipeline] step=finalize status=error frames=#{length(frames)}")
    {:push, frames, state}
  end

  defp finalize_error(%Context{error: reason, connection_state: state}) do
    notice_reason = if is_atom(reason), do: reason, else: :request_rejected

    notice =
      notice_reason
      |> notice_message()
      |> Message.serialize()

    {:push, [{:text, notice}], state}
  end

  defp finalize_ok(%Context{frames: [], connection_state: state}), do: {:ok, state}

  defp finalize_ok(%Context{frames: frames, connection_state: state}) when is_list(frames) do
    Logger.debug("[pipeline] step=finalize status=ok frames=#{length(frames)}")
    {:push, frames, state}
  end

  defp notice_message(:prefix_too_short),
    do: Message.notice("restricted: filter prefix too short")

  defp notice_message(:invalid_message_format), do: Message.notice("invalid message format")

  defp notice_message(:unsupported_json_escape),
    do: Message.notice("invalid message: unsupported JSON escape")

  defp notice_message(:unsupported_json_literals),
    do: Message.notice("invalid message: unsupported JSON literal control")

  defp notice_message(:unsupported_message_type), do: Message.notice("unsupported message type")

  defp notice_message(:invalid_event_id),
    do: Message.notice("invalid: event ID does not match hash")

  defp notice_message(:invalid_event_created_at),
    do: Message.notice("invalid: invalid created_at")

  defp notice_message(:invalid_event_sig),
    do: Message.notice("invalid: event signature verification failed")

  defp notice_message(:query_failed), do: Message.notice("could not query events")
  defp notice_message(:insert_failed), do: Message.notice("could not store event")

  defp notice_message(:auth_required),
    do: Message.notice("auth-required: please authenticate")

  defp notice_message(:auth_failed), do: Message.notice("auth-required: authentication failed")

  defp notice_message(:invalid_stage_result), do: Message.notice("invalid pipeline result")

  defp notice_message(_reason), do: Message.notice("request rejected")

  defp log_pipeline_start(%Context{connection_state: connection_state}) do
    Logger.debug("[pipeline] request status=received messages=#{connection_state.messages}")
  end

  defp log_stage_error(stage_name, {:error, reason, %Context{} = context}) do
    Logger.warning(
      "[pipeline] step=#{stage_name} status=error reason=#{inspect(reason)} " <>
        "message_count=#{context.connection_state.messages}"
    )
  end

  defp stage_name(stage) when is_atom(stage),
    do: stage |> Module.split() |> List.last()

  defp stage_name(stage), do: stage
end
