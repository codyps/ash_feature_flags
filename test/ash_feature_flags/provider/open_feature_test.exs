defmodule AshFeatureFlags.Provider.OpenFeatureTest do
  use AshFeatureFlags.Case, async: false

  alias AshFeatureFlags.{Context, Flag}
  alias AshFeatureFlags.Provider.OpenFeature
  alias AshFeatureFlags.Test.FakeHTTP

  @opts [base_url: "http://flagd.test:8016", http_client: FakeHTTP]

  defp flag(attrs \\ []), do: struct(Flag, Keyword.merge([name: :new_checkout], attrs))
  defp context, do: Context.build(actor: actor(role: :editor, tenant: "acme"))

  describe "OFREP evaluation" do
    test "reads the boolean value" do
      FakeHTTP.stub(200, %{"key" => "new-checkout", "value" => true, "reason" => "STATIC"})

      assert {:ok, true} = OpenFeature.enabled?(flag(), context(), @opts)
    end

    test "posts to the per-flag OFREP path" do
      FakeHTTP.stub(200, %{"value" => false})
      OpenFeature.enabled?(flag(), context(), @opts)

      assert FakeHTTP.last_request().url ==
               "http://flagd.test:8016/ofrep/v1/evaluate/flags/new-checkout"
    end

    test "sends a targetingKey, as the protocol requires" do
      FakeHTTP.stub(200, %{"value" => true})
      OpenFeature.enabled?(flag(), context(), @opts)

      evaluation_context = FakeHTTP.last_request().body["context"]

      assert is_binary(evaluation_context["targetingKey"])
      assert evaluation_context["roles"] == "editor"
      assert evaluation_context["tenant"] == "acme"
    end

    test "anonymous callers still get a targetingKey" do
      FakeHTTP.stub(200, %{"value" => true})
      OpenFeature.enabled?(flag(), Context.build([]), @opts)

      assert FakeHTTP.last_request().body["context"]["targetingKey"] == "anonymous"
    end

    test "a custom path prefix is honoured" do
      FakeHTTP.stub(200, %{"value" => true})
      OpenFeature.enabled?(flag(), context(), Keyword.put(@opts, :path_prefix, "/flags"))

      assert FakeHTTP.last_request().url == "http://flagd.test:8016/flags/new-checkout"
    end

    test "an OFREP error payload becomes an error" do
      FakeHTTP.stub(200, %{"errorCode" => "FLAG_NOT_FOUND", "errorDetails" => "nope"})

      assert {:error, {:ofrep_error, "FLAG_NOT_FOUND", "nope"}} =
               OpenFeature.enabled?(flag(), context(), @opts)
    end

    test "a 404 becomes an error rather than a silent false" do
      FakeHTTP.stub(404, %{})

      assert {:error, {:flag_not_found, "new-checkout", _}} =
               OpenFeature.enabled?(flag(), context(), @opts)
    end

    test "reads the variant" do
      FakeHTTP.stub(200, %{"value" => true, "variant" => "treatment"})

      assert {:ok, "treatment"} = OpenFeature.variant(flag(), context(), @opts)
    end
  end

  describe "delegating to an in-process OpenFeature SDK" do
    defmodule FakeClient do
      @moduledoc false
      def get_boolean_value(key, _default, context) do
        send(self(), {:sdk_called, key, context})
        true
      end

      def get_string_value(_key, _default, _context), do: "control"
    end

    test "no HTTP call is made when a client is configured" do
      assert {:ok, true} = OpenFeature.enabled?(flag(), context(), client: FakeClient)

      assert_received {:sdk_called, "new-checkout", context}
      assert context["targetingKey"]
      assert FakeHTTP.last_request() == nil
    end

    test "variants go through the client too" do
      assert {:ok, "control"} = OpenFeature.variant(flag(), context(), client: FakeClient)
    end
  end

  describe "init/1" do
    test "requires a base_url or a client" do
      assert {:error, message} = OpenFeature.init([])
      assert message =~ ":base_url"

      assert {:ok, _} = OpenFeature.init(base_url: "http://x")
      assert {:ok, _} = OpenFeature.init(client: FakeClient)
    end
  end
end
