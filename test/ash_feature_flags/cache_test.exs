defmodule AshFeatureFlags.CacheTest do
  use AshFeatureFlags.Case, async: false

  alias AshFeatureFlags.{Cache, Context, Evaluator, Flag}

  defmodule CountingProvider do
    @moduledoc "Counts evaluations so caching is observable."

    @behaviour AshFeatureFlags.Provider

    @impl true
    def enabled?(_flag, context, _opts) do
      :counters.add(counter(), 1, 1)
      {:ok, context.roles == [:admin]}
    end

    def counter do
      case Process.get(:counter) do
        nil ->
          ref = :counters.new(1, [])
          Process.put(:counter, ref)
          ref

        ref ->
          ref
      end
    end

    def count, do: :counters.get(counter(), 1)
  end

  setup do
    Cache.clear()
    Process.delete(:counter)
    :ok
  end

  defp evaluate(flag, context) do
    Evaluator.enabled?(flag, context, provider: CountingProvider)
  end

  describe "caching" do
    test "a ttl of 0 hits the provider every time" do
      flag = %Flag{name: :thing, ttl: 0}
      context = Context.build(actor: actor(role: :admin))

      for _ <- 1..3, do: evaluate(flag, context)

      assert CountingProvider.count() == 3
    end

    test "a non-zero ttl reuses the answer" do
      flag = %Flag{name: :thing, ttl: 60_000}
      context = Context.build(actor: actor(role: :admin))

      for _ <- 1..5, do: evaluate(flag, context)

      assert CountingProvider.count() == 1
    end

    test "different actors do not share a cache entry" do
      # Otherwise a percentage rollout would leak between users, which is the
      # subtlest way to get flags wrong.
      flag = %Flag{name: :thing, ttl: 60_000}

      assert evaluate(flag, Context.build(actor: actor(role: :admin))) == true
      assert evaluate(flag, Context.build(actor: actor(role: :editor))) == false
      assert CountingProvider.count() == 2
    end

    test "different flags do not share a cache entry" do
      context = Context.build(actor: actor(role: :admin))

      evaluate(%Flag{name: :one, ttl: 60_000}, context)
      evaluate(%Flag{name: :two, ttl: 60_000}, context)

      assert CountingProvider.count() == 2
    end

    test "entries expire" do
      flag = %Flag{name: :thing, ttl: 20}
      context = Context.build(actor: actor(role: :admin))

      evaluate(flag, context)
      Process.sleep(40)
      evaluate(flag, context)

      assert CountingProvider.count() == 2
    end

    test "invalidate/1 drops one flag's entries and leaves the rest" do
      context = Context.build(actor: actor(role: :admin))
      one = %Flag{name: :one, ttl: 60_000}
      two = %Flag{name: :two, ttl: 60_000}

      evaluate(one, context)
      evaluate(two, context)
      assert CountingProvider.count() == 2

      AshFeatureFlags.invalidate("one")

      evaluate(one, context)
      evaluate(two, context)

      assert CountingProvider.count() == 3
    end

    test "errors are never cached" do
      defmodule FlakyProvider do
        @behaviour AshFeatureFlags.Provider
        @impl true
        def enabled?(_flag, _context, _opts) do
          count = (Process.get(:calls) || 0) + 1
          Process.put(:calls, count)
          if count < 3, do: {:error, :boom}, else: {:ok, true}
        end
      end

      flag = %Flag{name: :flaky, ttl: 60_000, default: false}
      context = Context.build([])

      refute Evaluator.enabled?(flag, context, provider: FlakyProvider)
      refute Evaluator.enabled?(flag, context, provider: FlakyProvider)
      # Had the failure been cached, this would still be false.
      assert Evaluator.enabled?(flag, context, provider: FlakyProvider)
    end
  end

  describe "telemetry" do
    test "emits a stop event with the result and its source" do
      :telemetry.attach(
        "test-handler",
        [:ash_feature_flags, :evaluate, :stop],
        fn event, measurements, metadata, _ ->
          send(self(), {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-handler") end)

      flag = %Flag{name: :thing, ttl: 60_000}
      context = Context.build(actor: actor(role: :admin))

      evaluate(flag, context)
      assert_received {:telemetry, _, %{duration: _}, %{flag: :thing, source: :provider}}

      evaluate(flag, context)
      assert_received {:telemetry, _, _, %{source: :cache}}
    end

    test "a role short-circuit is reported as such" do
      :telemetry.attach(
        "role-handler",
        [:ash_feature_flags, :evaluate, :stop],
        fn _event, _measurements, metadata, _ -> send(self(), {:source, metadata.source}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("role-handler") end)

      evaluate(
        %Flag{name: :thing, enabled_for_roles: [:admin]},
        Context.build(actor: actor(role: :admin))
      )

      assert_received {:source, :role}
    end
  end
end
