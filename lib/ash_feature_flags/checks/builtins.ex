defmodule AshFeatureFlags.Checks.Builtins do
  @moduledoc """
  Policy checks you can use anywhere Ash policy checks are accepted.

  Ash fixes the set of modules imported into the `policies` and
  `field_policies` blocks, so import these yourself in resources where you want
  the sugar:

      defmodule MyApp.Shop.Order do
        use Ash.Resource,
          domain: MyApp.Shop,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshFeatureFlags]

        import AshFeatureFlags.Checks.Builtins

        policies do
          policy action(:checkout) do
            forbid_unless flag_enabled(:new_checkout)
            authorize_if actor_attribute_equals(:role, :customer)
          end
        end
      end

  Without the import, the tuple form works identically:
  `{AshFeatureFlags.Checks.FlagEnabled, flag: :new_checkout}`.

  A resource does not need the `AshFeatureFlags` extension to use these — an
  undeclared flag falls back to `config :ash_feature_flags, :flags` and then to
  a default-off flag whose key is the dasherized name.
  """

  alias AshFeatureFlags.Checks.{FlagDisabled, FlagEnabled, FlagVariant}

  @doc """
  Passes while `flag` is on.

  `flag` may be a list, in which case all of them must be on (pass
  `match: :any` to require only one).
  """
  @spec flag_enabled(atom() | [atom()], keyword()) :: {module(), keyword()}
  def flag_enabled(flag, opts \\ []) do
    {FlagEnabled, Keyword.put(opts, :flag, flag)}
  end

  @doc """
  Passes while `flag` is off.
  """
  @spec flag_disabled(atom() | [atom()], keyword()) :: {module(), keyword()}
  def flag_disabled(flag, opts \\ []) do
    {FlagDisabled, Keyword.put(opts, :flag, flag)}
  end

  @doc """
  Passes when `flag` resolves to `variant`.
  """
  @spec flag_variant(atom() | [atom()], String.t(), keyword()) :: {module(), keyword()}
  def flag_variant(flag, variant, opts \\ []) do
    {FlagVariant, opts |> Keyword.put(:flag, flag) |> Keyword.put(:variant, variant)}
  end
end
