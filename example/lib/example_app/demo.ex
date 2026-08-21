defmodule ExampleApp.Demo do
  @moduledoc """
  Runs one scenario matrix against a provider, and prints what happened.

  Every check states what it expects *and why*, so the output doubles as an
  explanation of how flags and policies interact. The same matrix runs against
  all four backends — if Flipt and flagd produce the same table as the
  in-memory provider, the abstraction is doing its job.
  """

  require Ash.Query

  alias ExampleApp.{Fixtures, Providers, Report}

  @doc """
  Seeds the backend, runs the checks, prints the report.

  Returns `{passed, failed}`.
  """
  @spec run(Providers.name(), keyword()) :: {non_neg_integer(), non_neg_integer()}
  def run(provider, opts \\ []) do
    # Activate first, so the heading reports the address actually in use.
    Providers.activate(provider, opts)
    Report.heading(provider)

    case Providers.seed(provider) do
      :ok ->
        world = Fixtures.reset!()
        results = checks(provider, world)
        Report.results(results)
        tally(results)

      {:error, reason} ->
        Report.unreachable(provider, reason)
        {0, 0}
    end
  end

  defp tally(results) do
    passed = Enum.count(results, &match?({:check, _, _, true, _}, &1))
    failed = Enum.count(results, &match?({:check, _, _, false, _}, &1))
    {passed, failed}
  end

  ## The scenarios

  defp checks(provider, world) do
    List.flatten([
      {:section, "flag state, as each backend expresses it"},
      flag_state_checks(world),
      {:section, "actions — the guard vetoes, it never grants"},
      action_checks(world),
      {:section, "attributes — visibility follows the flag"},
      attribute_checks(world),
      {:section, "rollout — bucketing is stable per actor"},
      rollout_checks(),
      toggle_section(provider, world)
    ])
  end

  defp flag_state_checks(world) do
    [
      check(
        "express-checkout is on",
        "seeded on in every backend",
        fn -> flag?(:express_checkout, world.customer) end,
        true
      ),
      check(
        "gift-wrapping is off for a customer",
        "seeded off in every backend",
        fn -> flag?(:gift_wrapping, world.customer) end,
        false
      ),
      check(
        "gift-wrapping is on for an admin",
        "enabled_for_roles [:admin] short-circuits the backend",
        fn -> flag?(:gift_wrapping, world.admin) end,
        true
      ),
      check(
        "fraud-tooling is on for support",
        "backend-side targeting rule on the roles property",
        fn -> flag?(:fraud_tooling, world.support) end,
        true
      ),
      check(
        "fraud-tooling is off for a customer",
        "same rule, different actor",
        fn -> flag?(:fraud_tooling, world.customer) end,
        false
      )
    ]
  end

  defp action_checks(world) do
    [
      check(
        "customer may express_checkout their own order",
        "flag on + ownership rule passes",
        fn -> allowed?(world.order, :express_checkout, world.customer) end,
        true
      ),
      check(
        "support may NOT express_checkout",
        "flag is on, but the resource's own policy refuses — a flag cannot grant",
        fn -> allowed?(world.order, :express_checkout, world.support) end,
        false
      ),
      check(
        "customer may NOT add_gift_wrap",
        "policy would allow it; the guard vetoes because the flag is off",
        fn -> allowed?(world.order, :add_gift_wrap, world.customer) end,
        false
      ),
      check(
        "admin may add_gift_wrap",
        "enabled_for_roles [:admin] turns the flag on for them",
        fn -> allowed?(world.order, :add_gift_wrap, world.admin) end,
        true
      ),
      check(
        "Ash.can? agrees, so a UI can hide the button",
        "guards are policies, so can?/3 reflects them",
        fn -> Ash.can?({world.order, :add_gift_wrap, %{}}, world.customer) end,
        false
      ),
      check(
        "the refusal carries the declared message",
        ~s|message: "Gift wrapping is not available yet."|,
        fn ->
          case update(world.order, :add_gift_wrap, world.customer) do
            {:error, error} -> Exception.message(error) =~ "Gift wrapping is not available yet"
            _ -> false
          end
        end,
        true
      )
    ]
  end

  defp attribute_checks(world) do
    [
      check(
        "predicted_ltv is hidden from a customer",
        "ml-scoring is off, so the field policy denies it",
        fn -> hidden?(world.order.id, :predicted_ltv, world.customer) end,
        true
      ),
      check(
        "predicted_ltv is hidden from an admin too",
        "field guards are about the flag, not the role",
        fn -> hidden?(world.order.id, :predicted_ltv, world.admin) end,
        true
      ),
      check(
        "filtering on predicted_ltv is refused",
        "prevent_filtering? closes the bisection leak a field policy leaves open",
        fn ->
          match?(
            {:error, _},
            ExampleApp.Shop.Order
            |> Ash.Query.filter(predicted_ltv > 100)
            |> Ash.read(actor: world.customer)
          )
        end,
        true
      ),
      check(
        "fraud_notes is visible to support",
        "fraud-tooling is targeted at them in the backend",
        fn -> not hidden?(world.order.id, :fraud_notes, world.support) end,
        true
      ),
      check(
        "fraud_notes is hidden from a customer",
        "same flag, different evaluation context",
        fn -> hidden?(world.order.id, :fraud_notes, world.customer) end,
        true
      ),
      check(
        "filtering on fraud_notes is still allowed",
        "prevent_filtering? false — hidden from responses, safe to filter",
        fn ->
          match?(
            {:ok, _},
            ExampleApp.Shop.Order
            |> Ash.Query.filter(not is_nil(fraud_notes))
            |> Ash.read(actor: world.customer)
          )
        end,
        true
      ),
      check(
        "unguarded fields are untouched",
        "the catch-all field policy keeps everything else visible",
        fn ->
          {:ok, order} = Ash.get(ExampleApp.Shop.Order, world.order.id, actor: world.customer)
          order.reference == world.order.reference
        end,
        true
      )
    ]
  end

  defp rollout_checks do
    actors = Fixtures.rollout_actors(200)

    on = Enum.count(actors, &flag?(:loyalty_pricing, &1))

    stable? =
      Enum.all?(Enum.take(actors, 20), fn actor ->
        values = for _ <- 1..5, do: flag?(:loyalty_pricing, actor)
        length(Enum.uniq(values)) == 1
      end)

    [
      check(
        "loyalty-pricing lands near 50% of 200 actors (#{on})",
        "hashed on the targeting key — the ash_authentication subject in a real app",
        fn -> on in 70..130 end,
        true
      ),
      check(
        "each actor gets the same answer every time",
        "nobody watches the feature flicker between page loads",
        fn -> stable? end,
        true
      )
    ]
  end

  # Only the writable backends can demonstrate a live toggle. Flipt and flagd
  # are seeded declaratively from files, so we say so instead of faking it.
  defp toggle_section(provider, world) do
    case Providers.put(provider, "ml-scoring", true) do
      :unsupported ->
        [
          {:section, "live toggle"},
          {:note,
           "skipped — #{provider} is seeded declaratively from docker/. Edit the file and restart the container to change it."}
        ]

      :ok ->
        AshFeatureFlags.invalidate("ml-scoring")

        results = [
          {:section, "live toggle — flipping ml-scoring on, mid-run"},
          check(
            "predicted_ltv becomes visible",
            "no redeploy, no restart",
            fn -> not hidden?(world.order.id, :predicted_ltv, world.customer) end,
            true
          ),
          check(
            "and filtering on it is allowed again",
            "the filter guard only applies while the flag is off",
            fn ->
              match?(
                {:ok, _},
                ExampleApp.Shop.Order
                |> Ash.Query.filter(predicted_ltv > 100)
                |> Ash.read(actor: world.customer)
              )
            end,
            true
          )
        ]

        Providers.put(provider, "ml-scoring", false)
        AshFeatureFlags.invalidate("ml-scoring")
        results
    end
  end

  ## Helpers

  defp check(label, why, fun, expected) do
    actual =
      try do
        fun.()
      rescue
        exception -> {:raised, exception}
      end

    {:check, label, why, actual == expected, describe(actual)}
  end

  defp describe(true), do: "yes"
  defp describe(false), do: "no"
  defp describe({:raised, exception}), do: "raised " <> inspect(exception.__struct__)
  defp describe(other), do: inspect(other)

  # `resource:` is what lets the runtime API see the `flag` declarations in the
  # resource's `feature_flags` block — the `enabled_for_roles` short-circuit,
  # the provider override, the declared default. Without it a flag falls back
  # to application config and then to default-off.
  defp flag?(flag, actor) do
    AshFeatureFlags.enabled?(flag, actor: actor, resource: ExampleApp.Shop.Order)
  end

  defp allowed?(order, action, actor) do
    match?({:ok, _}, update(order, action, actor))
  end

  defp update(order, action, actor) do
    order
    |> Ash.Changeset.for_update(action, %{})
    |> Ash.update(actor: actor)
  end

  defp hidden?(id, field, actor) do
    {:ok, order} = Ash.get(ExampleApp.Shop.Order, id, actor: actor)
    match?(%Ash.ForbiddenField{}, Map.get(order, field))
  end
end
