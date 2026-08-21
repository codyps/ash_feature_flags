defmodule ExampleApp.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      ExampleApp.Repo,
      {Phoenix.PubSub, name: ExampleApp.PubSub},
      ExampleAppWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ExampleApp.Supervisor)
  end
end
