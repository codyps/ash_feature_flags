defmodule AshFeatureFlags.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [AshFeatureFlags.Cache] ++ provider_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: AshFeatureFlags.Supervisor)
  end

  # Providers that need a process (a poller, an SDK client) can say so by
  # exporting `child_spec/1`; list them under `:providers` to have them
  # supervised here rather than wiring them into your own tree.
  defp provider_children do
    :ash_feature_flags
    |> Application.get_env(:providers, [])
    |> Enum.flat_map(fn provider ->
      {module, opts} = AshFeatureFlags.Provider.split(provider)

      if Code.ensure_loaded?(module) and function_exported?(module, :child_spec, 1) do
        List.wrap(module.child_spec(opts))
      else
        []
      end
    end)
  end
end
