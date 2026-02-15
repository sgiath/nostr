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

    %{
      "name" => Keyword.get(relay_info, :name),
      "description" => Keyword.get(relay_info, :description),
      "pubkey" => Keyword.get(relay_info, :pubkey),
      "contact" => Keyword.get(relay_info, :contact),
      "software" => Keyword.get(relay_info, :software),
      "version" => Keyword.get(relay_info, :version),
      "supported_nips" => Keyword.get(relay_info, :supported_nips, []),
      "limits" => Keyword.get(relay_info, :limits, %{})
    }
  end
end
