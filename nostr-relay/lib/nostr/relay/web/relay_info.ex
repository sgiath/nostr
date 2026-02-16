defmodule Nostr.Relay.Web.RelayInfo do
  @moduledoc """
  Builds the NIP-11 relay information document returned by GET `/`.

  Values are sourced from application env defaults in `config/config.exs` and may be
  overridden per environment.
  """

  @type t() :: %{required(String.t()) => term()}

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
    nip29 = Application.get_env(:nostr_relay, :nip29, [])
    supported_nips = supported_nips(Keyword.get(relay_info, :supported_nips, []), nip29)
    self_pubkey = Keyword.get(relay_identity, :self_pub)

    %{
      "name" => Keyword.get(relay_info, :name),
      "description" => Keyword.get(relay_info, :description),
      "pubkey" => Keyword.get(relay_info, :pubkey),
      "self" => self_pubkey,
      "contact" => Keyword.get(relay_info, :contact),
      "software" => Keyword.get(relay_info, :software),
      "version" => Keyword.get(relay_info, :version),
      "supported_nips" => supported_nips,
      "limits" => Keyword.get(relay_info, :limits, %{})
    }
  end

  defp supported_nips(current, nip29) when is_list(current) and is_list(nip29) do
    current
    |> ensure_nip70()
    |> maybe_include_nip29(nip29)
  end

  defp ensure_nip70(nips) when is_list(nips), do: Enum.uniq(nips ++ [70])

  defp maybe_include_nip29(current, nip29) do
    if Keyword.get(nip29, :enabled, false) do
      Enum.uniq(current ++ [29])
    else
      Enum.reject(current, &(&1 == 29))
    end
  end
end
