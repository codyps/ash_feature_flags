import Config

# Where the demo looks for the services in docker-compose.yml. Override when
# they run somewhere else:
#
#     FLIPT_URL=http://flipt.internal:8080 mix demo --provider flipt
config :example_app,
  flipt_url: System.get_env("FLIPT_URL", "http://localhost:8080"),
  flagd_url: System.get_env("FLAGD_URL", "http://localhost:8016"),
  flipt_namespace: System.get_env("FLIPT_NAMESPACE", "default")
