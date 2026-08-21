import Config

config :example_app, ExampleAppWeb.Endpoint,
  server: true,
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  # Just the example. The library above it is a path dep; recompiling it per
  # request fights with `mix test` and `mix demo` over the same build lock, so
  # editing ash_feature_flags itself wants a server restart.
  reloadable_apps: [:example_app]

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
