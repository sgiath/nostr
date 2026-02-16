defmodule Nostr.Relay.DebugLog do
  @moduledoc """
  Optional debug logger that records every inbound/outbound WebSocket message to a file.

  Enable in config:

      config :nostr_relay, :debug_log,
        enabled: true,
        path: "debug.log"

  Log format (plain text, one line per message):

      2026-02-16T10:30:00.000Z [conn:0F3A] IN  ["EVENT",{"id":"..."}]
      2026-02-16T10:30:00.001Z [conn:0F3A] OUT ["OK","abc...",false,"invalid: ..."]

  When disabled (default), all functions are no-ops.
  """

  @spec enabled?() :: boolean()
  def enabled? do
    config()[:enabled] == true
  end

  @spec log_in(binary(), binary()) :: :ok
  def log_in(conn_id, raw_data) when is_binary(conn_id) and is_binary(raw_data) do
    if enabled?() do
      write_line(conn_id, "IN ", raw_data)
    else
      :ok
    end
  end

  @spec log_out(binary(), [{atom(), binary()}]) :: :ok
  def log_out(conn_id, frames) when is_binary(conn_id) and is_list(frames) do
    if enabled?() do
      Enum.each(frames, fn
        {:text, payload} -> write_line(conn_id, "OUT", payload)
        _other -> :ok
      end)
    else
      :ok
    end
  end

  @spec write_line(binary(), binary(), binary()) :: :ok
  defp write_line(conn_id, direction, payload) do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    line = "#{ts} [conn:#{conn_id}] #{direction} #{payload}\n"
    File.write(log_path(), line, [:append])
    :ok
  end

  defp config do
    Application.get_env(:nostr_relay, :debug_log, [])
  end

  defp log_path do
    Keyword.get(config(), :path, "debug.log")
  end
end
