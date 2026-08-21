defmodule AshFeatureFlags.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/your-org/ash_feature_flags"

  def project do
    [
      app: :ash_feature_flags,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "Feature flags for Ash resources: guard actions and hide attributes behind flags " <>
          "backed by Flipt, OpenFeature, LaunchDarkly or your own database.",
      package: package(),
      docs: docs(),
      name: "AshFeatureFlags",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {AshFeatureFlags.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.31"},
      {:spark, "~> 2.7"},
      {:jason, "~> 1.4"},
      # Only needed by the HTTP-backed providers (Flipt / OpenFeature / LaunchDarkly).
      {:req, "~> 0.5", optional: true},
      # Ash policies need a SAT solver at runtime.
      {:simple_sat, "~> 0.1", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: [:dev], runtime: false}
      # `ash_authentication` is integrated with, but never depended on: the
      # actor introspection in `AshFeatureFlags.Context` resolves it at
      # runtime, so it is used when present and ignored when not.
    ]
  end

  defp package do
    [
      name: :ash_feature_flags,
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      groups_for_modules: [
        Extension: [AshFeatureFlags, AshFeatureFlags.Info, AshFeatureFlags.Flag],
        Providers: [~r/AshFeatureFlags\.Provider/],
        Policies: [~r/AshFeatureFlags\.Checks/]
      ]
    ]
  end
end
