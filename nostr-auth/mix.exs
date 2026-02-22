defmodule NostrAuth.MixProject do
  use Mix.Project

  def project do
    [
      app: :nostr_auth,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:nostr_lib, path: "../nostr-lib"},
      {:plug, "~> 1.19"},

      # Development
      {:ex_check, "~> 0.16", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev], runtime: false},
      {:mix_test_watch, "~> 1.4", only: [:dev], runtime: false}
    ]
  end
end
