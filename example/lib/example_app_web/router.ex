defmodule ExampleAppWeb.Router do
  @moduledoc false

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ExampleAppWeb.Layouts, :root}
    plug :protect_from_forgery
  end

  scope "/", ExampleAppWeb do
    pipe_through :browser

    live("/", PlaygroundLive, :index)
  end
end
