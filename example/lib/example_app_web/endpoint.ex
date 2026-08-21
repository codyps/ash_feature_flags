defmodule ExampleAppWeb.Endpoint do
  @moduledoc """
  The playground's endpoint.

  Deliberately tiny: no esbuild, no tailwind, no `npm install`. Phoenix and
  LiveView each ship a prebuilt browser bundle inside their own `priv/static`,
  so the two `Plug.Static` lines below are the entire asset pipeline. `mix
  server` is all the setup there is.
  """

  use Phoenix.Endpoint, otp_app: :example_app

  # Signing salt is hardcoded because this is an example that only ever runs on
  # localhost. A real app reads it from the environment in `runtime.exs`.
  @session_options [
    store: :cookie,
    key: "_example_app_key",
    signing_salt: "cJ8bZ1qA",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug Plug.Static, at: "/js/phoenix", from: {:phoenix, "priv/static"}, gzip: false
  plug Plug.Static, at: "/js/live_view", from: {:phoenix_live_view, "priv/static"}, gzip: false

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.Session, @session_options
  plug ExampleAppWeb.Router
end
