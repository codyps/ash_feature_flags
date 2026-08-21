defmodule AshFeatureFlags.Cache do
  @moduledoc """
  A tiny ETS TTL cache in front of providers.

  Flag evaluation happens inside `Ash.Policy.Authorizer`'s strict check, which
  runs on every action — without a cache an HTTP-backed provider would add a
  round trip per request. Entries are keyed per flag *and* per actor, so a
  percentage rollout still varies between users.

  TTL is resolved per flag: `ttl` on the flag, else `cache_ttl` on the
  resource's `feature_flags` section, else
  `config :ash_feature_flags, cache_ttl: 5_000`. A TTL of `0` disables caching
  for that flag, which is what you want for a kill switch.
  """

  use GenServer

  @table __MODULE__
  @sweep_interval :timer.seconds(60)

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Fetches a cached value, or computes and stores it.

  `fun` returns `{:ok, value}` or `{:error, reason}`; errors are never cached.
  """
  @spec fetch(term(), non_neg_integer(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def fetch(_key, 0, fun), do: fun.()

  def fetch(key, ttl, fun) do
    case get(key) do
      {:ok, value} ->
        {:ok, value}

      :miss ->
        case fun.() do
          {:ok, value} = ok ->
            put(key, value, ttl)
            ok

          other ->
            other
        end
    end
  end

  @doc "Reads a cached value without computing it."
  @spec get(term()) :: {:ok, term()} | :miss
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        if expires_at > now(), do: {:ok, value}, else: :miss

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc "Writes a value with a TTL in milliseconds."
  @spec put(term(), term(), non_neg_integer()) :: :ok
  def put(_key, _value, 0), do: :ok

  def put(key, value, ttl) do
    :ets.insert(@table, {key, value, now() + ttl})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Drops everything, or every entry for one flag.

  Call this from a webhook when your flag backend tells you something changed,
  instead of running with a very short TTL.

  Accepts either the provider-side key (`"new-checkout"`) or the flag name
  (`:new_checkout`) — an atom is dasherized through `AshFeatureFlags.Flag.key/1`
  so that both forms hit the same entries. Passing `:new_checkout` and having
  it silently match nothing would leave a stale flag in place with no error.
  """
  @spec clear(String.t() | atom() | nil) :: :ok
  def clear(flag_key \\ nil)

  def clear(nil) do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def clear(flag_key) when is_atom(flag_key) do
    clear(AshFeatureFlags.Flag.key(%AshFeatureFlags.Flag{name: flag_key}))
  end

  def clear(flag_key) do
    flag_key = to_string(flag_key)

    # Boolean evaluations are keyed `{provider, key, hash}` and variants
    # `{:variant, {provider, key, hash}}`; both have to go, or a toggled flag
    # would keep serving its old variant.
    :ets.match_delete(@table, {{:_, flag_key, :_}, :_, :_})
    :ets.match_delete(@table, {{:variant, {:_, flag_key, :_}}, :_, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Owned here so overrides survive the process that set them.
    AshFeatureFlags.Provider.Static.ensure_table()

    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now()}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
