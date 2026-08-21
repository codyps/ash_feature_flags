import Config

if config_env() == :test do
  config :ash_feature_flags,
    provider: AshFeatureFlags.Provider.Static,
    # No caching in tests: a flag flipped mid-test must take effect
    # immediately, and there is no network round trip to amortize anyway.
    cache_ttl: 0

  config :ash, :validate_domain_resource_inclusion?, false
  config :ash, :disable_async?, true
  config :logger, level: :warning
end
