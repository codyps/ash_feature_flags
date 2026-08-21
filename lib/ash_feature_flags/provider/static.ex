defmodule AshFeatureFlags.Provider.Static do
  @moduledoc """
  Flags from application config or an in-memory override table.

  The default provider, and the one you want in tests: no network, no
  database, and flags can be flipped from inside a test without touching the
  rest of the suite.

  ## Config

      config :ash_feature_flags, AshFeatureFlags.Provider.Static,
        flags: %{
          "new-checkout" => true,
          "ml-pricing" => false,
          "checkout-experiment" => "treatment"
        }

  Keys are the provider-side flag keys (dasherized names by default). A value
  may be a boolean, a variant string, or a function taking the evaluation
  context — the last is how you express targeting without a real backend:

      flags: %{
        "beta" => fn context -> :admin in context.roles end
      }

  ## In tests

      test "checkout is gated" do
        AshFeatureFlags.Provider.Static.put("new-checkout", false)
        assert {:error, %Ash.Error.Forbidden{}} = Shop.checkout(order, actor: user)
      end

  `put/2` writes to an ETS table that takes precedence over config, and
  `AshFeatureFlags.Provider.Static.reset/0` clears it. Overrides are global, so
  use `async: false` for tests that set them, or scope flags per actor with a
  function value.
  """

  @behaviour AshFeatureFlags.Provider

  alias AshFeatureFlags.{Context, Flag}

  @table __MODULE__

  @impl AshFeatureFlags.Provider
  def enabled?(%Flag{} = flag, %Context{} = context, opts) do
    case lookup(Flag.key(flag), context, opts) do
      :error -> {:ok, flag.default}
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, nil} -> {:ok, false}
      # A variant string counts as "on"; use `variant:` on the flag or
      # `flag_variant/2` if you care which one.
      {:ok, _variant} -> {:ok, true}
    end
  end

  @impl AshFeatureFlags.Provider
  def variant(%Flag{} = flag, %Context{} = context, opts) do
    case lookup(Flag.key(flag), context, opts) do
      :error -> {:ok, nil}
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, true} -> {:ok, "on"}
      {:ok, _} -> {:ok, nil}
    end
  end

  @impl AshFeatureFlags.Provider
  def put(%Flag{} = flag, value, _opts), do: put(Flag.key(flag), value)

  @doc """
  Overrides a flag at runtime. Returns `:ok`.
  """
  @spec put(String.t() | atom(), boolean() | String.t() | (Context.t() -> term())) :: :ok
  def put(key, value) do
    ensure_table()
    :ets.insert(@table, {to_string(key), value})
    AshFeatureFlags.Cache.clear(to_string(key))
    :ok
  end

  @doc "Removes all runtime overrides, falling back to config."
  @spec reset() :: :ok
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    AshFeatureFlags.Cache.clear()
    :ok
  end

  defp lookup(key, context, opts) do
    with :error <- fetch_override(key),
         :error <- fetch_configured(key, opts) do
      :error
    else
      {:ok, fun} when is_function(fun, 1) -> {:ok, fun.(context)}
      {:ok, fun} when is_function(fun, 0) -> {:ok, fun.()}
      {:ok, value} -> {:ok, value}
    end
  end

  defp fetch_override(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp fetch_configured(key, opts) do
    flags =
      opts[:flags] ||
        Application.get_env(:ash_feature_flags, __MODULE__, [])[:flags] ||
        %{}

    with :error <- do_fetch(flags, key) do
      do_fetch(flags, String.to_atom(key))
    end
  end

  defp do_fetch(flags, key) when is_map(flags), do: Map.fetch(flags, key)

  defp do_fetch(flags, key) when is_list(flags) do
    case Keyword.fetch(flags, key) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp do_fetch(_flags, _key), do: :error

  @doc false
  def ensure_table do
    :ets.whereis(@table)
    |> case do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
