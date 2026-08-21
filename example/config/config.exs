import Config

config :example_app,
  ecto_repos: [ExampleApp.Repo],
  ash_domains: [ExampleApp.Accounts, ExampleApp.Shop, ExampleApp.Flags]

config :example_app, ExampleApp.Repo,
  database: Path.expand("../priv/example_app_#{config_env()}.db", __DIR__),
  pool_size: 5

# The demo overrides `:provider` per run, so this is only the fallback for
# anything that runs outside `mix demo`.
config :ash_feature_flags,
  provider: AshFeatureFlags.Provider.Static,
  # Zero TTL so a flag flipped in the demo is visible on the next line. In
  # production you would leave this at the default 5s, or higher, and call
  # `AshFeatureFlags.invalidate/1` from your backend's webhook.
  cache_ttl: 0,
  on_error: :default,
  role_keys: [:role, :roles]

# The LiveView playground — `mix server`. secret_key_base is hardcoded because
# this only ever runs on localhost; a real app reads it from the environment.
config :example_app, ExampleAppWeb.Endpoint,
  # Bandit rather than Cowboy: the example already depends on it for the
  # loopback server behind `mix demo --stub`, so this adds nothing.
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  render_errors: [formats: [html: ExampleAppWeb.ErrorHTML], layout: false],
  pubsub_server: ExampleApp.PubSub,
  live_view: [signing_salt: "Kq2Yr7Vm"],
  secret_key_base: String.duplicate("example-app-playground-not-a-secret", 2)

config :phoenix, :json_library, Jason

config :ash, :validate_domain_resource_inclusion?, false
config :logger, level: :warning

import_config "#{config_env()}.exs"
