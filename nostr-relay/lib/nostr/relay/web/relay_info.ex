defmodule Nostr.Relay.Web.RelayInfo do
  @moduledoc """
  Builds the NIP-11 relay information document returned by GET `/`.

  Values are sourced from application env defaults in `config/config.exs` and may be
  overridden per environment.
  """

  @type t() :: %{required(String.t()) => term()}
  @limitation_keys [
    :max_message_length,
    :max_subscriptions,
    :max_limit,
    :max_subid_length,
    :max_event_tags,
    :max_content_length,
    :min_pow_difficulty,
    :payment_required,
    :restricted_writes,
    :created_at_lower_limit,
    :created_at_upper_limit,
    :default_limit
  ]

  @spec json() :: binary()
  def json do
    metadata()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> JSON.encode!()
  end

  @spec metadata() :: t()
  def metadata do
    relay_info = Application.get_env(:nostr_relay, :relay_info, [])
    relay_identity = Application.get_env(:nostr_relay, :relay_identity, [])
    auth = Application.get_env(:nostr_relay, :auth, [])
    nip29 = Application.get_env(:nostr_relay, :nip29, [])
    supported_nips = supported_nips(Keyword.get(relay_info, :supported_nips, []), nip29)
    limitation = limitation(relay_info, auth)
    self_pubkey = Keyword.get(relay_identity, :self_pub)

    %{
      "name" => Keyword.get(relay_info, :name),
      "description" => Keyword.get(relay_info, :description),
      "banner" => Keyword.get(relay_info, :banner),
      "icon" => Keyword.get(relay_info, :icon),
      "pubkey" => Keyword.get(relay_info, :pubkey),
      "self" => self_pubkey,
      "contact" => Keyword.get(relay_info, :contact),
      "terms_of_service" => Keyword.get(relay_info, :terms_of_service),
      "software" => Keyword.get(relay_info, :software),
      "version" => Keyword.get(relay_info, :version),
      "supported_nips" => supported_nips,
      "limitation" => limitation,
      "payments_url" => Keyword.get(relay_info, :payments_url),
      "fees" => normalize_object(Keyword.get(relay_info, :fees))
    }
  end

  defp supported_nips(current, nip29) when is_list(current) and is_list(nip29) do
    current
    |> ensure_nip13_and_nip70()
    |> maybe_include_nip29(nip29)
  end

  defp ensure_nip13_and_nip70(nips) when is_list(nips), do: Enum.uniq(nips ++ [13, 70])

  defp maybe_include_nip29(current, nip29) do
    if Keyword.get(nip29, :enabled, false) do
      Enum.uniq(current ++ [29])
    else
      Enum.reject(current, &(&1 == 29))
    end
  end

  defp limitation(relay_info, auth) do
    relay_info
    |> Keyword.get(:limitation, %{})
    |> map_or_empty()
    |> Map.take(@limitation_keys)
    |> maybe_put_auth_required(auth)
    |> normalize_object()
  end

  defp maybe_put_auth_required(%{} = limitation, auth) do
    Map.put(limitation, :auth_required, Keyword.get(auth, :required, false))
  end

  defp normalize_object(%{} = value) do
    value
    |> Enum.map(fn {key, map_value} -> {to_string(key), normalize_object(map_value)} end)
    |> Map.new()
  end

  defp normalize_object(value) when is_list(value) do
    Enum.map(value, &normalize_object/1)
  end

  defp normalize_object(value), do: value

  defp map_or_empty(%{} = value), do: value
  defp map_or_empty(_value), do: %{}
end
