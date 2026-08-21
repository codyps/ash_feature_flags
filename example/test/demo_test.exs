defmodule ExampleApp.DemoTest do
  @moduledoc """
  A smoke test so the example cannot rot silently.

  It runs the same matrix `mix demo` does, against the two providers that need
  no service plus the two HTTP ones pointed at the bundled stub — so all four
  code paths are exercised in CI without Docker.
  """

  use ExUnit.Case, async: false

  alias ExampleApp.{Demo, Providers, StubServer}

  setup_all do
    {:ok, urls} = StubServer.start()
    %{urls: urls}
  end

  for provider <- [:static, :sqlite] do
    test "every scenario passes against #{provider}" do
      assert {passed, 0} = Demo.run(unquote(provider))
      assert passed > 20
    end
  end

  test "every scenario passes against Flipt over HTTP", %{urls: urls} do
    assert {passed, 0} = Demo.run(:flipt, base_url: urls.flipt)
    assert passed > 18
  end

  test "every scenario passes against OFREP over HTTP", %{urls: urls} do
    assert {passed, 0} = Demo.run(:flagd, base_url: urls.flagd)
    assert passed > 18
  end

  test "all four providers agree" do
    # The point of the abstraction: the same resource, the same policies, four
    # very different backends, identical answers.
    results =
      for provider <- Providers.names() do
        base_url =
          case provider do
            :flipt -> "http://127.0.0.1:18080"
            :flagd -> "http://127.0.0.1:18016"
            _ -> nil
          end

        Providers.activate(provider, base_url: base_url)
        :ok = Providers.seed(provider)
        world = ExampleApp.Fixtures.reset!()

        %{
          express:
            AshFeatureFlags.enabled?(:express_checkout,
              actor: world.customer,
              resource: ExampleApp.Shop.Order
            ),
          gift_customer:
            AshFeatureFlags.enabled?(:gift_wrapping,
              actor: world.customer,
              resource: ExampleApp.Shop.Order
            ),
          gift_admin:
            AshFeatureFlags.enabled?(:gift_wrapping,
              actor: world.admin,
              resource: ExampleApp.Shop.Order
            ),
          fraud_support:
            AshFeatureFlags.enabled?(:fraud_tooling,
              actor: world.support,
              resource: ExampleApp.Shop.Order
            ),
          fraud_customer:
            AshFeatureFlags.enabled?(:fraud_tooling,
              actor: world.customer,
              resource: ExampleApp.Shop.Order
            )
        }
      end

    assert length(Enum.uniq(results)) == 1, "providers disagreed: #{inspect(results)}"
  end
end
