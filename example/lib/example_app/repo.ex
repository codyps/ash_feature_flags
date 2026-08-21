defmodule ExampleApp.Repo do
  @moduledoc """
  SQLite, so the demo runs with nothing installed.

  Point this at `AshPostgres.Repo` and the `postgres` service in
  `docker-compose.yml` to see the same code against Postgres.
  """

  use AshSqlite.Repo, otp_app: :example_app

  def installed_extensions, do: []
end
