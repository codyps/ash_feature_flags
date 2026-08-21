defmodule AshFeatureFlags.VerifierTest do
  use ExUnit.Case, async: false

  @tmp_dir Path.join(System.tmp_dir!(), "ash_feature_flags_verifier_test")

  setup_all do
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf(@tmp_dir) end)
    :ok
  end

  # Spark verifiers run from `@after_verify`, which Elixir executes in the
  # parallel checker rather than inline — so `Code.compile_string/1` would
  # print the error and return normally. Compiling a real file lets us see it.
  defp compile(body, name) do
    path = Path.join(@tmp_dir, "#{name}.ex")

    File.write!(path, """
    defmodule #{name} do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshFeatureFlags]

      attributes do
        uuid_primary_key :id
        attribute :title, :string, public?: true
        attribute :secret, :string, public?: false
      end

      actions do
        defaults [:read, :destroy, create: :*, update: :*]
      end

      #{body}
    end
    """)

    Kernel.ParallelCompiler.compile([path], return_diagnostics: true)
  end

  defp error_message(body) do
    name = "Verifier#{System.unique_integer([:positive])}"

    assert {:error, [%{message: message} | _], _diagnostics} = compile(body, name)
    message
  end

  test "an undeclared flag is caught at compile time" do
    message =
      error_message("""
      feature_flags do
        guard_action [:create], flag: :never_declared
      end
      """)

    assert message =~ "Undeclared feature flag"
    assert message =~ ":never_declared"
  end

  test "guarding an action that does not exist is caught" do
    message =
      error_message("""
      feature_flags do
        flag :thing
        guard_action [:teleport], flag: :thing
      end
      """)

    assert message =~ "do not exist"
    assert message =~ ":teleport"
  end

  test "guarding a field that does not exist is caught" do
    message =
      error_message("""
      feature_flags do
        flag :thing
        guard_attribute [:nonexistent], flag: :thing
      end
      """)

    assert message =~ "no such attribute"
  end

  test "guarding a primary key explains why it cannot work" do
    message =
      error_message("""
      feature_flags do
        flag :thing
        guard_attribute [:id], flag: :thing
      end
      """)

    assert message =~ "part of the primary key"
    assert message =~ "guard_action"
  end

  test "guarding a private field explains the setting that would make it work" do
    message =
      error_message("""
      feature_flags do
        flag :thing
        guard_attribute [:secret], flag: :thing
      end
      """)

    assert message =~ "it is private"
    assert message =~ "private_fields"
  end

  test "a provider missing required options is caught at compile time" do
    message =
      error_message("""
      feature_flags do
        provider AshFeatureFlags.Provider.Flipt

        flag :thing
        guard_action [:create], flag: :thing
      end
      """)

    assert message =~ "Invalid provider configuration"
    assert message =~ ":base_url"
  end

  test "a per-flag provider is validated too" do
    message =
      error_message("""
      feature_flags do
        flag :thing do
          provider {AshFeatureFlags.Provider.AshResource, []}
        end

        guard_action [:create], flag: :thing
      end
      """)

    assert message =~ "for flag :thing"
    assert message =~ ":resource"
  end

  test "a valid section compiles" do
    name = "Verifier#{System.unique_integer([:positive])}"

    assert {:ok, [_ | _], _diagnostics} =
             compile(
               """
               feature_flags do
                 flag :thing do
                   default true
                 end

                 guard_action [:create], flag: :thing
                 guard_attribute [:title], flag: :thing
               end
               """,
               name
             )
  end
end
