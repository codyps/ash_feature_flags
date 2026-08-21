defmodule AshFeatureFlags.Provider.FliptTest do
  use AshFeatureFlags.Case, async: false

  alias AshFeatureFlags.{Context, Flag}
  alias AshFeatureFlags.Provider.Flipt
  alias AshFeatureFlags.Test.FakeHTTP

  @opts [base_url: "http://flipt.test:8080/", http_client: FakeHTTP]

  defp flag(attrs \\ []), do: struct(Flag, Keyword.merge([name: :new_checkout], attrs))

  defp context do
    Context.build(actor: actor(role: :editor, tenant: "acme"), resource: Post, action: :create)
  end

  describe "enabled?/3" do
    test "reads Flipt's boolean evaluation response" do
      FakeHTTP.stub(200, %{"enabled" => true, "reason" => "MATCH_EVALUATION_REASON"})

      assert {:ok, true} = Flipt.enabled?(flag(), context(), @opts)
    end

    test "posts to the boolean evaluation endpoint" do
      FakeHTTP.stub(200, %{"enabled" => false})
      Flipt.enabled?(flag(), context(), @opts)

      assert %{method: :post, url: url, body: body} = FakeHTTP.last_request()
      assert url == "http://flipt.test:8080/evaluate/v1/boolean"
      assert body["flagKey"] == "new-checkout"
      assert body["namespaceKey"] == "default"
    end

    test "dasherizes the flag name unless a key is given" do
      FakeHTTP.stub(200, %{"enabled" => true})

      Flipt.enabled?(flag(name: :ml_pricing_v2), context(), @opts)
      assert FakeHTTP.last_request().body["flagKey"] == "ml-pricing-v2"

      Flipt.enabled?(flag(name: :ml_pricing_v2, key: "custom_key"), context(), @opts)
      assert FakeHTTP.last_request().body["flagKey"] == "custom_key"
    end

    test "sends a stable entity id so percentage rollouts do not flicker" do
      FakeHTTP.stub(200, %{"enabled" => true})
      context = context()

      Flipt.enabled?(flag(), context, @opts)
      first = FakeHTTP.last_request().body["entityId"]

      Flipt.enabled?(flag(), context, @opts)
      assert FakeHTTP.last_request().body["entityId"] == first
      assert first != "anonymous"
    end

    test "anonymous actors get a constant entity id" do
      FakeHTTP.stub(200, %{"enabled" => true})
      Flipt.enabled?(flag(), Context.build([]), @opts)

      assert FakeHTTP.last_request().body["entityId"] == "anonymous"
    end

    test "sends roles, tenant, resource and action as segment properties" do
      FakeHTTP.stub(200, %{"enabled" => true})
      Flipt.enabled?(flag(), context(), @opts)

      properties = FakeHTTP.last_request().body["context"]

      assert properties["roles"] == "editor"
      assert properties["tenant"] == "acme"
      assert properties["resource"] == "AshFeatureFlags.Test.Post"
      assert properties["action"] == "create"
    end

    test "merges the flag's static context" do
      FakeHTTP.stub(200, %{"enabled" => true})
      Flipt.enabled?(flag(context: %{tier: "gold"}), context(), @opts)

      assert FakeHTTP.last_request().body["context"]["tier"] == "gold"
    end

    test "sends a bearer token when configured" do
      FakeHTTP.stub(200, %{"enabled" => true})
      Flipt.enabled?(flag(), context(), Keyword.put(@opts, :token, "s3cret"))

      assert {"authorization", "Bearer s3cret"} in FakeHTTP.last_request().headers
    end

    test "resolves a token from the environment" do
      System.put_env("TEST_FLIPT_TOKEN", "from-env")
      on_exit(fn -> System.delete_env("TEST_FLIPT_TOKEN") end)

      FakeHTTP.stub(200, %{"enabled" => true})
      Flipt.enabled?(flag(), context(), Keyword.put(@opts, :token, {:system, "TEST_FLIPT_TOKEN"}))

      assert {"authorization", "Bearer from-env"} in FakeHTTP.last_request().headers
    end

    test "an unknown flag is an error, so the flag's default applies" do
      FakeHTTP.stub(404, %{"message" => "not found"})

      assert {:error, {:flag_not_found, "new-checkout"}} =
               Flipt.enabled?(flag(), context(), @opts)
    end

    test "a transport failure is returned, not raised" do
      FakeHTTP.stub(fn _, _, _, _, _ -> {:error, :econnrefused} end)

      assert {:error, :econnrefused} = Flipt.enabled?(flag(), context(), @opts)
    end

    test "a missing base_url is reported clearly" do
      assert {:error, message} = Flipt.enabled?(flag(), context(), http_client: FakeHTTP)
      assert message =~ ":base_url"
    end
  end

  describe "variant/3" do
    test "reads variantKey" do
      FakeHTTP.stub(200, %{"match" => true, "variantKey" => "treatment"})

      assert {:ok, "treatment"} = Flipt.variant(flag(), context(), @opts)
    end

    test "no segment match means no variant, not an error" do
      FakeHTTP.stub(200, %{"match" => false})

      assert {:ok, nil} = Flipt.variant(flag(), context(), @opts)
    end
  end

  describe "end to end through the evaluator" do
    test "an unreachable Flipt falls back to the flag's default" do
      FakeHTTP.stub(fn _, _, _, _, _ -> {:error, :nxdomain} end)

      assert AshFeatureFlags.enabled?(:some_flag,
               provider: {Flipt, @opts},
               definition: %Flag{name: :some_flag, default: true}
             )

      refute AshFeatureFlags.enabled?(:some_flag,
               provider: {Flipt, @opts},
               definition: %Flag{name: :some_flag, default: false}
             )
    end

    test "on_error: :disable ignores the declared default" do
      FakeHTTP.stub(fn _, _, _, _, _ -> {:error, :nxdomain} end)

      refute AshFeatureFlags.enabled?(:some_flag,
               provider: {Flipt, @opts},
               on_error: :disable,
               definition: %Flag{name: :some_flag, default: true}
             )
    end

    test "on_error: :raise surfaces the failure" do
      FakeHTTP.stub(fn _, _, _, _, _ -> {:error, :nxdomain} end)

      assert_raise AshFeatureFlags.Error.ProviderError, ~r/nxdomain/, fn ->
        AshFeatureFlags.enabled?(:some_flag,
          provider: {Flipt, @opts},
          on_error: :raise,
          definition: %Flag{name: :some_flag}
        )
      end
    end
  end
end
