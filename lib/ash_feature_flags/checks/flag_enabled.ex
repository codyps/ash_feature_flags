defmodule AshFeatureFlags.Checks.FlagEnabled do
  @moduledoc """
  An `Ash.Policy.SimpleCheck` that passes while a feature flag is on.

  This is the seam between feature flags and `ash_authentication`: it is an
  ordinary policy check, so it sits next to role and ownership checks and obeys
  the same `authorize_if` / `forbid_unless` semantics.

      policies do
        policy action_type(:read) do
          authorize_if actor_attribute_equals(:role, :admin)
          authorize_if expr(author_id == ^actor(:id))
        end

        # Everyone above still needs the flag to be on.
        policy action(:publish) do
          forbid_unless flag_enabled(:publishing_v2)
          authorize_if always()
        end
      end

  Usable in field policies too, which is how attribute visibility works:

      field_policies do
        field_policy :experimental_score do
          authorize_if flag_enabled(:ml_pricing)
        end

        field_policy :* do
          authorize_if always()
        end
      end

  ## Options

    * `:flag` - flag name or list of names (required)
    * `:match` - `:all` (default) or `:any` when several flags are given
    * `:variant` - require this variant instead of a plain boolean
  """

  use Ash.Policy.SimpleCheck

  alias AshFeatureFlags.{Context, Evaluator}

  @impl Ash.Policy.Check
  def describe(opts) do
    flags = opts |> Keyword.fetch!(:flag) |> List.wrap()

    subject =
      case flags do
        [flag] -> "feature flag #{inspect(flag)} is"
        many -> "feature flags #{inspect(many)} are #{joiner(opts)}"
      end

    case opts[:variant] do
      nil -> "#{subject} enabled"
      variant -> "#{subject} set to variant #{inspect(variant)}"
    end
  end

  defp joiner(opts), do: if(opts[:match] == :any, do: "any of them", else: "all")

  @impl Ash.Policy.SimpleCheck
  def match?(actor, authorizer, opts) do
    context = Context.from_authorizer(actor, authorizer)
    check(context, opts)
  end

  @doc false
  def check(%Context{} = context, opts) do
    flags = opts |> Keyword.fetch!(:flag) |> List.wrap()
    match = opts[:match] || :all

    evaluate = fn name ->
      flag = Evaluator.resolve_flag(name, context, opts)

      flag =
        case opts[:variant] do
          nil -> flag
          variant -> %{flag | variant: variant}
        end

      Evaluator.enabled?(flag, context, opts)
    end

    case match do
      :all -> Enum.all?(flags, evaluate)
      :any -> Enum.any?(flags, evaluate)
    end
  end
end

defmodule AshFeatureFlags.Checks.FlagDisabled do
  @moduledoc """
  The inverse of `AshFeatureFlags.Checks.FlagEnabled`.

  Handy for kill switches, where the readable form is "forbid if the panic flag
  is on":

      policy action_type(:create) do
        forbid_if flag_enabled(:signups_paused)
        authorize_if always()
      end

  ...or for gating the *old* path during a migration:

      policy action(:legacy_checkout) do
        authorize_if flag_disabled(:new_checkout)
      end
  """

  use Ash.Policy.SimpleCheck

  alias AshFeatureFlags.{Checks.FlagEnabled, Context}

  @impl Ash.Policy.Check
  def describe(opts), do: "not " <> FlagEnabled.describe(opts)

  @impl Ash.Policy.SimpleCheck
  def match?(actor, authorizer, opts) do
    not FlagEnabled.check(Context.from_authorizer(actor, authorizer), opts)
  end
end

defmodule AshFeatureFlags.Checks.FlagVariant do
  @moduledoc """
  Passes when a multivariate flag resolves to a specific variant.

      policy action(:read) do
        authorize_if flag_variant(:checkout_experiment, "treatment")
      end
  """

  use Ash.Policy.SimpleCheck

  alias AshFeatureFlags.{Context, Evaluator}

  @impl Ash.Policy.Check
  def describe(opts) do
    "feature flag #{inspect(opts[:flag])} has variant #{inspect(opts[:variant])}"
  end

  @impl Ash.Policy.SimpleCheck
  def match?(actor, authorizer, opts) do
    context = Context.from_authorizer(actor, authorizer)

    opts
    |> Keyword.fetch!(:flag)
    |> List.wrap()
    |> Enum.all?(&Evaluator.variant?(&1, context, opts[:variant], opts))
  end
end
