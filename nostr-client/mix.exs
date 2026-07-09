defmodule NostrClient.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      # Library
      app: :nostr_client,
      version: @version,

      # Elixir
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),

      # Documentation
      name: "Nostr Client",
      source_url: "https://github.com/sgiath/nostr",
      homepage_url: "https://sgiath.dev/libraries#nostr_client",
      description: """
      OTP WebSocket client for communicating with Nostr relays
      """,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      mod: {Nostr.Client.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # {:nostr_lib, path: "../nostr-lib"},
      {:nostr_lib, "~> 0.2"},
      {:mint_web_socket, "~> 1.0"},
      {:req, "~> 0.6"},

      # Testing
      {:plug, "~> 1.0", only: :test},

      # Development
      {:ex_check, "~> 0.16", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev], runtime: false},
      {:mix_test_watch, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  # Documentation

  defp package do
    [
      name: "nostr_client",
      maintainers: ["sgiath <nostr@sgiath.dev>"],
      files: ~w(lib docs .formatter.exs mix.exs README* LICENSE* CHANGELOG*),
      licenses: ["WTFPL"],
      links: %{
        "GitHub" => "https://github.com/sgiath/nostr",
        "Nostr specs" => "https://github.com/nostr-protocol/nips"
      }
    ]
  end

  defp docs do
    [
      authors: ["sgiath <nostr@sgiath.dev>"],
      main: "overview",
      api_reference: false,
      formatters: ["html"],
      source_ref: "v#{@version}",
      source_url: "https://github.com/sgiath/nostr",
      extra_section: "Guides",
      extras: extras(),
      groups_for_extras: groups_for_extras(),
      groups_for_modules: groups_for_modules()
    ]
  end

  defp extras do
    [
      # Introduction
      "docs/introduction/overview.md",
      "docs/introduction/installation.md",
      # Guides
      "docs/guides/single-relay.md",
      "docs/guides/multi-relay-sessions.md",
      "docs/guides/relay-auth-and-info.md",
      "docs/guides/count-and-negentropy.md"
    ]
  end

  defp groups_for_extras do
    [
      Introduction: ~r"docs/introduction/.?",
      Guides: ~r"docs/guides/.?"
    ]
  end

  defp groups_for_modules do
    [
      "Public API": [
        Nostr.Client
      ],
      "Relay Discovery and Auth": [
        Nostr.Client.RelayInfo,
        Nostr.Client.AuthSigner
      ],
      "Sessions and Subscriptions": [
        Nostr.Client.Session,
        Nostr.Client.RelaySession,
        Nostr.Client.Subscription,
        Nostr.Client.SessionSubscription
      ],
      Supervision: [
        Nostr.Client.Application,
        Nostr.Client.SessionManager,
        Nostr.Client.SessionSupervisor,
        Nostr.Client.SubscriptionSupervisor,
        Nostr.Client.MultiSessionSupervisor
      ]
    ]
  end
end
