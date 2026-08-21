defmodule ExampleApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :example_app,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: false,
      elixirc_paths: elixirc_paths(Mix.env()),
      # So `mix server` picks up edits without a restart.
      listeners: [Phoenix.CodeReloader],
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ExampleApp.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash_feature_flags, path: ".."},
      {:ash, "~> 3.31"},

      # The flag table lives in SQLite here so the demo runs with no server.
      # Swapping to `ash_postgres` is a two-line change; see the README.
      {:ash_sqlite, "~> 0.2"},
      {:ash_sql, "~> 0.6", override: true},

      # Talking to Flipt and flagd.
      {:req, "~> 0.5"},

      # The LiveView playground — `mix server`. Phoenix is only here for the
      # example; ash_feature_flags itself has no web dependency.
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.1"},

      # `Phoenix.LiveViewTest` parses the rendered HTML with this.
      {:lazy_html, "~> 0.1", only: :test},

      # The bundled loopback server behind `mix demo --stub`, which lets the
      # HTTP providers be demonstrated before Docker is running.
      {:bandit, "~> 1.12"},
      {:plug, "~> 1.19"},
      {:jason, "~> 1.4"},
      {:simple_sat, "~> 0.1"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ash_sqlite.create", "ash_sqlite.migrate"],
      reset: ["ash_sqlite.drop", "ash_sqlite.create", "ash_sqlite.migrate"],
      server: ["phx.server"]
    ]
  end
end
