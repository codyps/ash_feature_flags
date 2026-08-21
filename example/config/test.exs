import Config

config :example_app, ExampleApp.Repo,
  database: Path.expand("../priv/example_app_test.db", __DIR__)

config :example_app, ExampleAppWeb.Endpoint,
  server: false,
  secret_key_base: String.duplicate("example-app-test-secret-key-base-x", 2)
