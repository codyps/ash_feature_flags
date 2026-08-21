defmodule AshFeatureFlags.RegressionsTest do
  @moduledoc """
  One test per bug found in review. Each of these failed before its fix.

  The cache ones matter more than they look: the suite runs with
  `cache_ttl: 0`, so every cache-key collision was invisible under the test
  config and only appeared with the documented 5s production default. These
  tests set a TTL explicitly.
  """

  use AshFeatureFlags.Case, async: false

  alias AshFeatureFlags.{Cache, Context, Evaluator, Flag}

  setup do
    Cache.clear()
    :ok
  end

  describe "cache key: variants" do
    test "two variants of one flag do not share a cache entry" do
      # The cached value for a variant flag is the *comparison result*, not the
      # variant, so leaving `variant` out of the key handed one cohort the
      # other's answer for the whole TTL.
      set_flag("experiment", "control")

      context = Context.build([])
      treatment = %Flag{name: :experiment, ttl: 60_000, variant: "treatment"}
      control = %Flag{name: :experiment, ttl: 60_000, variant: "control"}

      assert Evaluator.enabled?(control, context)
      refute Evaluator.enabled?(treatment, context)

      # ...and in the other order, in case the first one to run wins.
      Cache.clear()
      refute Evaluator.enabled?(treatment, context)
      assert Evaluator.enabled?(control, context)
    end

    test "a variant flag does not collide with the plain boolean flag" do
      set_flag("experiment", "control")
      context = Context.build([])

      assert Evaluator.enabled?(%Flag{name: :experiment, ttl: 60_000}, context)

      refute Evaluator.enabled?(
               %Flag{name: :experiment, ttl: 60_000, variant: "treatment"},
               context
             )
    end
  end

  describe "cache key: provider options" do
    defmodule NamespacedProvider do
      @moduledoc "Answers according to the namespace it was configured with."
      @behaviour AshFeatureFlags.Provider

      @impl true
      def enabled?(_flag, _context, opts), do: {:ok, opts[:namespace] == "billing"}
    end

    test "the same module with different options is a different backend" do
      # `Provider`'s own docs advertise pointing one module at two namespaces
      # or environments; they must not share cache entries.
      flag = %Flag{name: :thing, ttl: 60_000}
      context = Context.build([])

      assert Evaluator.enabled?(flag, context,
               provider: {NamespacedProvider, namespace: "billing"}
             )

      refute Evaluator.enabled?(flag, context,
               provider: {NamespacedProvider, namespace: "marketing"}
             )
    end
  end

  describe "cache key: targeting inputs" do
    defmodule ContextProvider do
      @moduledoc "Targets on whatever the test asks it to."
      @behaviour AshFeatureFlags.Provider

      @impl true
      def enabled?(_flag, context, opts) do
        {:ok, apply(opts[:rule], [context])}
      end
    end

    defp evaluate(context, rule) do
      Evaluator.enabled?(%Flag{name: :thing, ttl: 60_000}, context,
        provider: {ContextProvider, rule: rule}
      )
    end

    test "action is part of the key" do
      # `guard_action` compiles to per-action policies, and the action is sent
      # to the provider as a targeting property. A flag rolled out for reads
      # only must not read as on for writes.
      rule = &(&1.action == :read)

      assert evaluate(Context.build(action: :read), rule)
      refute evaluate(Context.build(action: :update), rule)
    end

    test "resource is part of the key" do
      rule = &(&1.resource == Post)

      assert evaluate(Context.build(resource: Post), rule)
      refute evaluate(Context.build(resource: Note), rule)
    end

    test "public actor attributes are part of the key" do
      # Same id — so the targeting key is identical and the *attribute* is the
      # only thing that could distinguish the two entries.
      id = Ash.UUID.generate()
      rule = &(&1.attributes[:email] == "a@example.com")

      assert evaluate(Context.build(actor: actor(id: id, email: "a@example.com")), rule)
      refute evaluate(Context.build(actor: actor(id: id, email: "b@example.com")), rule)
    end

    test "tenant and roles are still part of the key" do
      assert evaluate(Context.build(tenant: "acme"), &(&1.tenant == "acme"))
      refute evaluate(Context.build(tenant: "other"), &(&1.tenant == "acme"))

      assert evaluate(Context.build(roles: [:admin]), &(:admin in &1.roles))
      refute evaluate(Context.build(roles: [:editor]), &(:admin in &1.roles))
    end
  end

  describe "provider modules that have not been loaded yet" do
    alias AshFeatureFlags.Provider.Flipt
    alias AshFeatureFlags.Test.FakeHTTP

    test "variant/3 is found on a provider module that has not been loaded" do
      # `function_exported?/3` answers false for a module that has not been
      # loaded, and nothing else on this path would autoload it — so variant
      # lookups failed permanently on first use in any interactive-mode
      # deployment (dev, test, and any non-`:embedded` release).
      #
      # It has to be a provider with a .beam on disk: a module defined inside
      # this file cannot be reloaded once deleted.
      FakeHTTP.stub(200, %{"match" => true, "variantKey" => "treatment"})

      # Unload last, so nothing reloads it before the call under test.
      :code.purge(Flipt)
      :code.delete(Flipt)

      refute :erlang.function_exported(Flipt, :variant, 3),
             "precondition: the module must be unloaded for this test to mean anything"

      assert {:ok, "treatment"} =
               Evaluator.variant(:experiment, Context.build([]),
                 provider: {Flipt, base_url: "http://flipt.test", http_client: FakeHTTP}
               )
    end
  end

  describe "invalidate/1 with a flag name" do
    defmodule CountingProvider do
      @behaviour AshFeatureFlags.Provider

      @impl true
      def enabled?(_flag, _context, _opts) do
        {:ok, :persistent_term.get({__MODULE__, :value}, false)}
      end
    end

    test "an atom is dasherized the same way the cache key is" do
      # `invalidate(:new_checkout)` stringified to "new_checkout" and matched
      # nothing, so the documented webhook path silently left stale values in
      # place for the rest of the TTL.
      flag = %Flag{name: :new_checkout, ttl: 60_000}
      context = Context.build([])

      :persistent_term.put({CountingProvider, :value}, false)
      refute Evaluator.enabled?(flag, context, provider: CountingProvider)

      :persistent_term.put({CountingProvider, :value}, true)

      refute Evaluator.enabled?(flag, context, provider: CountingProvider),
             "should still be cached"

      AshFeatureFlags.invalidate(:new_checkout)

      assert Evaluator.enabled?(flag, context, provider: CountingProvider)
    end

    test "the string key still works" do
      flag = %Flag{name: :new_checkout, ttl: 60_000}
      context = Context.build([])

      :persistent_term.put({CountingProvider, :value}, false)
      refute Evaluator.enabled?(flag, context, provider: CountingProvider)

      :persistent_term.put({CountingProvider, :value}, true)
      AshFeatureFlags.invalidate("new-checkout")

      assert Evaluator.enabled?(flag, context, provider: CountingProvider)
    end
  end

  describe "context subject fields" do
    test "query and changeset are nil, never false" do
      # `match?(...) && subject` left `false` in the other field, so a provider
      # written as `case context.query do nil -> ...; %Ash.Query{} -> ... end`
      # raised CaseClauseError.
      query = Ash.Query.new(Post)
      context = Context.from_authorizer(nil, %{subject: query, resource: Post})

      assert context.query == query
      assert context.changeset == nil

      changeset = Ash.Changeset.new(Post)
      context = Context.from_authorizer(nil, %{subject: changeset, resource: Post})

      assert context.changeset == changeset
      assert context.query == nil
    end
  end

  describe "error_ttl" do
    defmodule FlakyProvider do
      @behaviour AshFeatureFlags.Provider

      @impl true
      def enabled?(_flag, _context, _opts) do
        :counters.add(counter(), 1, 1)
        {:error, :boom}
      end

      def counter do
        case :persistent_term.get({__MODULE__, :counter}, nil) do
          nil ->
            ref = :counters.new(1, [])
            :persistent_term.put({__MODULE__, :counter}, ref)
            ref

          ref ->
            ref
        end
      end

      def reset, do: :persistent_term.erase({__MODULE__, :counter})
      def count, do: :counters.get(counter(), 1)
    end

    setup do
      FlakyProvider.reset()
      :ok
    end

    test "failures are not cached by default" do
      flag = %Flag{name: :flaky, ttl: 60_000, default: false}
      context = Context.build([])

      for _ <- 1..3, do: Evaluator.enabled?(flag, context, provider: FlakyProvider)

      assert FlakyProvider.count() == 3
    end

    test "error_ttl caches the fallback, so an outage stops costing a timeout each time" do
      flag = %Flag{name: :flaky, ttl: 60_000, default: false}
      context = Context.build([])

      for _ <- 1..3 do
        Evaluator.enabled?(flag, context, provider: FlakyProvider, error_ttl: 60_000)
      end

      assert FlakyProvider.count() == 1
    end

    test "a flag with caching off never caches its failures" do
      flag = %Flag{name: :flaky, ttl: 0, default: false}
      context = Context.build([])

      for _ <- 1..3 do
        Evaluator.enabled?(flag, context, provider: FlakyProvider, error_ttl: 60_000)
      end

      assert FlakyProvider.count() == 3
    end

    test "the cached fallback is the value on_error decided" do
      flag = %Flag{name: :flaky, ttl: 60_000, default: true}
      context = Context.build([])

      assert Evaluator.enabled?(flag, context, provider: FlakyProvider, error_ttl: 60_000)
      assert Evaluator.enabled?(flag, context, provider: FlakyProvider, error_ttl: 60_000)
      assert FlakyProvider.count() == 1
    end
  end

  describe "the Req client without req installed" do
    test "reports a distinguishable reason instead of looking like an outage" do
      # The install instructions used to be raised inside a rescued body, so a
      # missing optional dependency produced the same `{:error, _}` a network
      # failure does.
      assert {:error, {:missing_dependency, :req, message}} =
               AshFeatureFlags.HTTP.Req.request(:get, "http://x", [], nil,
                 req_module: NotAnInstalledReqModule
               )

      assert message =~ "req"
    end
  end

  describe "LaunchDarkly attribute keys" do
    test "caller-supplied string keys do not create atoms" do
      # `enabled?(:flag, context: Map.new(conn.params))` is a plausible way to
      # pass targeting data; String.to_atom on it is an unbounded atom table.
      before = :erlang.system_info(:atom_count)

      for index <- 1..500 do
        AshFeatureFlags.Provider.LaunchDarkly.enabled?(
          %Flag{name: :thing},
          Context.build(context: %{"never_seen_key_#{index}" => "v"}),
          client: __MODULE__.FakeLD
        )
      end

      assert :erlang.system_info(:atom_count) - before < 100
    end

    test "attribute names that are already atoms are preserved" do
      AshFeatureFlags.Provider.LaunchDarkly.enabled?(
        %Flag{name: :thing},
        Context.build(actor: actor(role: :admin), context: %{"from_params" => "x"}),
        client: __MODULE__.FakeLD
      )

      assert_received {:ld_context, ld_context}
      assert ld_context.roles == ["admin"]
      assert ld_context.kind == "user"
      assert Map.get(ld_context, "from_params") == "x"
    end

    defmodule FakeLD do
      @moduledoc false
      def variation(_key, context, default, _tag) do
        send(self(), {:ld_context, context})
        default
      end
    end
  end
end
