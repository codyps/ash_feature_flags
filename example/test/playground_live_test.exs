defmodule ExampleAppWeb.PlaygroundLiveTest do
  @moduledoc """
  The playground makes claims in its own copy. This checks they are true.

  Every assertion here is something you can also see by clicking: a field that
  is present or absent, a button that is drawn or not.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ExampleApp.{Fixtures, Providers, StubServer}

  @endpoint ExampleAppWeb.Endpoint

  setup_all do
    # The playground calls `Providers.activate/1` with no `base_url:`, so point
    # the HTTP providers at the bundled stub once, up front. `activate/2` stores
    # the address, so every later call picks it up.
    {:ok, urls} = StubServer.start()
    Providers.activate(:flipt, base_url: urls.flipt)
    Providers.activate(:flagd, base_url: urls.flagd)
    :ok
  end

  setup do
    # Each test starts from the Static backend in its seeded state, and from an
    # order nothing has checked out yet.
    Providers.activate(:static)
    :ok = Providers.seed(:static)
    Fixtures.reset!()

    %{conn: build_conn()}
  end

  test "a customer sees neither guarded field", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert html =~ "ORD-1001"
    refute rendered_ltv(view)
    refute rendered_fraud_notes(view)
  end

  test "support sees fraud_notes, because the backend targets the flag at them", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    refute rendered_fraud_notes(view)

    select_role(view, :support)

    assert rendered_fraud_notes(view)
    # Still no ml-scoring — a field guard is about the flag, not the role.
    refute rendered_ltv(view)
  end

  test "flipping ml-scoring on reveals predicted_ltv, and off hides it again", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    refute rendered_ltv(view)

    flip(view, "ml-scoring", true)
    assert rendered_ltv(view)
    assert render(view) =~ "480"

    flip(view, "ml-scoring", false)
    refute rendered_ltv(view)
  end

  test "the express checkout button follows the flag and the policy", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    # Customer: flag on, owns the order.
    assert has_element?(view, "button[phx-value-action=express_checkout]")

    # Support: same flag, but the resource's own policy refuses. A guard vetoes,
    # it never grants.
    select_role(view, :support)
    refute has_element?(view, "button[phx-value-action=express_checkout]")

    # Flag off: gone for the customer too.
    select_role(view, :customer)
    flip(view, "express-checkout", false)
    refute has_element?(view, "button[phx-value-action=express_checkout]")
  end

  test "only an admin gets the gift wrap button while the flag is off", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    refute has_element?(view, "button[phx-value-action=add_gift_wrap]")

    select_role(view, :admin)

    # `enabled_for_roles [:admin]` short-circuits the backend, which still says off.
    assert has_element?(view, "button[phx-value-action=add_gift_wrap]")
    assert render(view) =~ "gift-wrapping"
  end

  test "running a guarded action surfaces the declared refusal message", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    # The button is not drawn, but a hand-rolled event still has to be refused —
    # the guard is a policy, not a template concern.
    html =
      view
      |> render_click("run", %{"action" => "add_gift_wrap"})

    assert html =~ "Gift wrapping is not available yet"
  end

  test "express checkout actually runs for the customer", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    html =
      view
      |> element("button[phx-value-action=express_checkout]")
      |> render_click()

    assert html =~ "express_checkout succeeded"
  end

  test "a declarative backend has its toggles disabled rather than faked", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, "button[phx-value-key='ml-scoring']:not([disabled])")

    view
    |> element("button[phx-value-provider=flagd]")
    |> render_click()

    assert has_element?(view, "button[phx-value-key='ml-scoring'][disabled]")
    assert render(view) =~ "reads its whole state from docker/"
  end

  test "switching to the sqlite backend changes nothing the page shows", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    select_role(view, :support)
    before = visible_fields(view)

    view
    |> element("button[phx-value-provider=sqlite]")
    |> render_click()

    assert visible_fields(view) == before
  end

  ## Helpers

  defp select_role(view, role) do
    view
    |> element("button[phx-value-role=#{role}]")
    |> render_click()
  end

  defp flip(view, key, to) do
    view
    |> element("button[phx-value-key='#{key}'][phx-value-to='#{to}']")
    |> render_click()
  end

  # A guarded field always renders a row; `data-visible` says whether the value
  # came back or `%Ash.ForbiddenField{}` did.
  defp visible?(view, field) do
    has_element?(view, ~s|[data-field="#{field}"][data-visible="true"]|)
  end

  defp rendered_ltv(view), do: visible?(view, "predicted_ltv")

  defp rendered_fraud_notes(view), do: visible?(view, "fraud_notes")

  defp visible_fields(view) do
    %{ltv: rendered_ltv(view), fraud: rendered_fraud_notes(view)}
  end
end
