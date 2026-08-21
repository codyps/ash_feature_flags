defmodule ExampleAppWeb.PlaygroundLive do
  @moduledoc """
  One page, one order, three actors, four backends.

  `mix demo` proves the same things in a terminal; this proves them somewhere
  you can click. Change who you are or which backend answers, and watch fields
  and buttons appear and disappear.

  There are two ways to use a flag on this page, and it is worth knowing which
  is which:

    * **Declared on the resource.** `predicted_ltv`, `fraud_notes`,
      `express_checkout` and `add_gift_wrap` are guarded in
      `ExampleApp.Shop.Order`'s `feature_flags` block. This LiveView never asks
      whether those flags are on — it reads the order as the actor and renders
      what came back, and calls `Ash.can?/2` to decide whether to draw a button.
      A field that is off arrives as `%Ash.ForbiddenField{}`; the server never
      sent the value.

    * **Checked here, in the view.** The loyalty discount is not a resource
      concern, so it is an ordinary `AshFeatureFlags.enabled?/2` call in
      `assign_view_flags/1`. This is the "anywhere else in your app" case.

  The first kind is the one that cannot be got wrong: forget the `:if` in a
  template and a resource guard still refuses. Forget it around the discount and
  you have shipped the feature.
  """

  use Phoenix.LiveView

  alias ExampleApp.{Fixtures, Providers}
  alias ExampleApp.Shop.Order

  # The order the playground renders, and what each flag is responsible for.
  @flags [
    %{
      name: :express_checkout,
      key: "express-checkout",
      does: "Draws the Express checkout button (guard_action)"
    },
    %{
      name: :gift_wrapping,
      key: "gift-wrapping",
      does: "Draws the Add gift wrap button (guard_action, admins exempt)"
    },
    %{
      name: :ml_scoring,
      key: "ml-scoring",
      does: "Reveals predicted_ltv (guard_attribute)"
    },
    %{
      name: :fraud_tooling,
      key: "fraud-tooling",
      does: "Reveals fraud_notes (guard_attribute, targeted at support)"
    },
    %{
      name: :loyalty_pricing,
      key: "loyalty-pricing",
      does: "Shows the discount — checked in the LiveView, not the resource"
    }
  ]

  @roles [
    {:customer, "Customer", "ada@example.com"},
    {:support, "Support", "sam@example.com"},
    {:admin, "Admin", "root@example.com"}
  ]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(role: :customer, provider: :static, notice: nil)
      |> assign(world: Fixtures.ensure!())
      |> switch_provider(:static)

    {:ok, socket}
  end

  ## Events

  @impl Phoenix.LiveView
  def handle_event("select_role", %{"role" => role}, socket) do
    {:noreply, socket |> assign(role: String.to_existing_atom(role), notice: nil) |> load()}
  end

  def handle_event("select_provider", %{"provider" => provider}, socket) do
    {:noreply, switch_provider(assign(socket, notice: nil), String.to_existing_atom(provider))}
  end

  def handle_event("toggle_flag", %{"key" => key, "to" => to}, socket) do
    # `put/3` writes to the backend; `invalidate/1` drops the cached evaluation
    # so the next render sees it. In production you would call `invalidate/1`
    # from your flag provider's webhook instead of inline like this.
    case Providers.put(socket.assigns.provider, key, to == "true") do
      :ok ->
        AshFeatureFlags.invalidate(key)
        {:noreply, socket |> assign(notice: nil) |> load()}

      :unsupported ->
        {:noreply, assign(socket, notice: {:warn, declarative_notice(socket.assigns.provider)})}
    end
  end

  def handle_event("run", %{"action" => action}, socket) do
    action = String.to_existing_atom(action)

    result =
      socket.assigns.world.order
      |> Ash.Changeset.for_update(action, %{})
      |> Ash.update(actor: socket.assigns.actor)

    notice =
      case result do
        {:ok, _order} -> {:ok, "#{action} succeeded."}
        {:error, error} -> {:err, Exception.message(error)}
      end

    {:noreply, socket |> assign(world: Fixtures.ensure!(), notice: notice) |> load()}
  end

  def handle_event("reset", _params, socket) do
    socket =
      socket
      |> assign(world: Fixtures.reset!(), notice: {:ok, "Order rebuilt."})
      |> load()

    {:noreply, socket}
  end

  ## State

  defp switch_provider(socket, provider) do
    status = Providers.seed(provider)
    Providers.activate(provider)

    notice =
      case status do
        :ok -> socket.assigns[:notice]
        {:error, reason} -> {:err, unreachable_notice(provider, reason)}
      end

    socket
    |> assign(provider: provider, provider_status: status, notice: notice)
    |> load()
  end

  # Everything the page shows is derived here, once per interaction. Note that
  # the order is read *as the actor* — that is what makes a hidden field
  # genuinely absent rather than hidden in CSS.
  defp load(socket) do
    %{world: world, role: role} = socket.assigns
    actor = Map.fetch!(world, role)

    {:ok, order} = Ash.get(Order, world.order.id, actor: actor)

    socket
    |> assign(actor: actor, order: order)
    |> assign(flags: evaluate_flags(actor))
    |> assign(
      can: %{
        express_checkout: Ash.can?({order, :express_checkout, %{}}, actor),
        add_gift_wrap: Ash.can?({order, :add_gift_wrap, %{}}, actor)
      }
    )
    |> assign_view_flags()
  end

  # The flag panel's own reading of each flag. This is only for display — the
  # order card above it never consults these, it renders what Ash returned.
  defp evaluate_flags(actor) do
    Map.new(@flags, fn flag -> {flag.name, flag?(flag.name, actor)} end)
  end

  # The "anywhere in your app" case: a flag checked in the view because the
  # thing it controls is a view concern.
  defp assign_view_flags(socket) do
    assign(socket, loyalty?: flag?(:loyalty_pricing, socket.assigns.actor))
  end

  # `resource:` is what lets the runtime API see the resource's `feature_flags`
  # block — its `enabled_for_roles` short-circuit and its declared defaults.
  defp flag?(name, actor) do
    AshFeatureFlags.enabled?(name, actor: actor, resource: Order)
  end

  ## Render

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="wrap">
      <header class="masthead">
        <h1>ash_feature_flags playground</h1>
        <p>
          The same order, rendered for whoever you say you are, against whichever backend
          you point it at. Nothing below is hidden with CSS — a field that is off never
          leaves the server.
        </p>
      </header>

      <div class="columns">
        <div>
          <.actor_panel role={@role} actor={@actor} />
          <.provider_panel provider={@provider} status={@provider_status} />
          <.flag_panel flags={@flags} provider={@provider} role={@role} />
        </div>

        <div>
          <.notice notice={@notice} />
          <.order_panel
            order={@order}
            role={@role}
            can={@can}
            loyalty?={@loyalty?}
            flags={@flags}
          />
          <.legend_panel />
        </div>
      </div>
    </div>
    """
  end

  attr(:role, :atom, required: true)
  attr(:actor, :any, required: true)

  defp actor_panel(assigns) do
    assigns = assign(assigns, roles: @roles)

    ~H"""
    <section class="panel">
      <h2>Who am I</h2>
      <div class="panel-body">
        <div class="segmented">
          <button
            :for={{role, label, _email} <- @roles}
            type="button"
            phx-click="select_role"
            phx-value-role={role}
            aria-pressed={to_string(@role == role)}
          >
            {label}
          </button>
        </div>
        <p class="hint">
          Evaluating as <code>{@actor.email}</code>, role <code>{@actor.role}</code>.
          The role becomes the <code>roles</code> targeting property; the id becomes the
          targeting key a percentage rollout buckets on.
        </p>
      </div>
    </section>
    """
  end

  attr(:provider, :atom, required: true)
  attr(:status, :any, required: true)

  defp provider_panel(assigns) do
    assigns = assign(assigns, providers: Providers.names())

    ~H"""
    <section class="panel">
      <h2>Which backend answers</h2>
      <div class="panel-body">
        <div class="segmented">
          <button
            :for={name <- @providers}
            type="button"
            phx-click="select_provider"
            phx-value-provider={name}
            aria-pressed={to_string(@provider == name)}
          >
            {name}
          </button>
        </div>
        <p class="hint">{Providers.label(@provider)}</p>
        <p :if={@status != :ok} class="hint">
          Not answering — <code>docker compose up -d</code> starts it.
        </p>
      </div>
    </section>
    """
  end

  attr(:flags, :map, required: true)
  attr(:provider, :atom, required: true)
  attr(:role, :atom, required: true)

  defp flag_panel(assigns) do
    assigns =
      assign(assigns,
        definitions: @flags,
        writable?: Providers.writable?(assigns.provider)
      )

    ~H"""
    <section class="panel">
      <h2>Flags, as this backend sees them for me</h2>

      <div :for={flag <- @definitions} class="flag">
        <div class="flag-top">
          <code class="flag-key">{flag.key}</code>
          <span class={["pill", if(@flags[flag.name], do: "on", else: "off")]}>
            {if @flags[flag.name], do: "on", else: "off"}
          </span>
          <button
            type="button"
            class="toggle"
            disabled={not @writable?}
            phx-click="toggle_flag"
            phx-value-key={flag.key}
            phx-value-to={to_string(not @flags[flag.name])}
          >
            flip
          </button>
        </div>
        <div class="flag-why">{flag.does}</div>
      </div>

      <div :if={not @writable? or @role == :admin} class="panel-body">
        <p :if={not @writable?} class="hint">
          {declarative_notice(@provider)}
        </p>
        <p :if={@writable? and @role == :admin} class="hint">
          <code>gift-wrapping</code> reads on for you whatever the backend says —
          <code>enabled_for_roles [:admin]</code> on the resource short-circuits it.
        </p>
      </div>
    </section>
    """
  end

  attr(:order, :any, required: true)
  attr(:role, :atom, required: true)
  attr(:can, :map, required: true)
  attr(:loyalty?, :boolean, required: true)
  attr(:flags, :map, required: true)

  defp order_panel(assigns) do
    ~H"""
    <section class="panel">
      <h2>The order, as returned to me</h2>

      <div class="order">
        <h3>Order {@order.reference}</h3>
        <div class="ref">
          Read with <code>Ash.get(Order, id, actor: {@role})</code>
        </div>

        <div class="price">
          <span :if={@loyalty?} class="was">{money(@order.total_cents)}</span>
          {money(discounted(@order.total_cents, @loyalty?))}
        </div>
        <div class="ref">
          <%= if @loyalty? do %>
            10% loyalty discount — <code>loyalty-pricing</code> is on for you.
            Bucketed on your id, so it never flickers between page loads.
          <% else %>
            List price. <code>loyalty-pricing</code> is off for you — you fell outside
            the 50% bucket.
          <% end %>
        </div>

        <dl class="fields">
          <.field label="Express checkout">
            {if @order.express?, do: "yes", else: "not yet"}
          </.field>

          <.field label="Gift wrapped">
            {if @order.gift_wrapped?, do: "yes", else: "no"}
          </.field>

          <.guarded_field
            label="predicted_ltv"
            value={@order.predicted_ltv}
            flag="ml-scoring"
            shown="The model output is on the struct because the flag is on."
            hidden="Never sent. The field guard denied it, and filtering on it is refused too."
          />

          <.guarded_field
            label="fraud_notes"
            value={@order.fraud_notes}
            flag="fraud-tooling"
            shown="Visible because the backend targets this flag at support."
            hidden="Never sent. Same flag, different evaluation context."
          />
        </dl>

        <div class="actions">
          <button
            :if={@can.express_checkout}
            type="button"
            class="btn"
            phx-click="run"
            phx-value-action="express_checkout"
          >
            Express checkout
          </button>
          <div :if={not @can.express_checkout} class="withheld">
            No Express checkout button — <code>Ash.can?</code> said no.
            {express_reason(@role, @flags)}
          </div>

          <button
            :if={@can.add_gift_wrap}
            type="button"
            class="btn ghost"
            phx-click="run"
            phx-value-action="add_gift_wrap"
          >
            Add gift wrap
          </button>
          <div :if={not @can.add_gift_wrap} class="withheld">
            No gift wrap button — <code>gift-wrapping</code> is off, and the guard vetoes.
          </div>
        </div>

        <div class="actions">
          <button type="button" class="btn ghost" phx-click="reset">Reset order</button>
        </div>
      </div>
    </section>
    """
  end

  attr(:label, :string, required: true)
  slot(:inner_block, required: true)

  defp field(assigns) do
    ~H"""
    <div class="field">
      <dt>{@label}</dt>
      <dd>{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:flag, :string, required: true)
  attr(:shown, :string, required: true)
  attr(:hidden, :string, required: true)

  defp guarded_field(assigns) do
    ~H"""
    <div
      class={["field", guarded?(@value) && "hidden"]}
      data-field={@label}
      data-visible={to_string(not guarded?(@value))}
    >
      <dt>{@label}</dt>
      <dd>
        <%= if guarded?(@value) do %>
          <code>{"%Ash.ForbiddenField{}"}</code>
          <span class="note">{@hidden} (<code>{@flag}</code>)</span>
        <% else %>
          {@value}
          <span class="note">{@shown} (<code>{@flag}</code>)</span>
        <% end %>
      </dd>
    </div>
    """
  end

  attr(:notice, :any, required: true)

  defp notice(assigns) do
    ~H"""
    <div :if={@notice} class={["banner", notice_class(@notice)]}>
      {elem(@notice, 1)}
    </div>
    """
  end

  defp legend_panel(assigns) do
    ~H"""
    <section class="panel">
      <h2>What to try</h2>
      <div class="panel-body">
        <ul class="legend">
          <li>
            Switch to <strong>Support</strong> — <code>fraud_notes</code> appears, because
            the backend targets that flag at the <code>roles</code> property. The Express
            checkout button vanishes, because the resource's own policy refuses: a flag
            guard can veto an action, never grant one.
          </li>
          <li>
            Switch to <strong>Admin</strong> — the gift wrap button appears while
            <code>gift-wrapping</code> is still off everywhere, via
            <code>enabled_for_roles [:admin]</code>.
          </li>
          <li>
            Flip <code>ml-scoring</code> on — <code>predicted_ltv</code> arrives with no
            redeploy and no restart. Flip it back and it is gone again.
          </li>
          <li>
            Change the backend and nothing about the page changes. That is the point:
            the resource never names one.
          </li>
        </ul>
      </div>
    </section>
    """
  end

  ## View helpers

  defp guarded?(value), do: match?(%Ash.ForbiddenField{}, value)

  defp money(cents), do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  defp discounted(cents, true), do: round(cents * 0.9)
  defp discounted(cents, false), do: cents

  defp notice_class({kind, _message}), do: to_string(kind)

  defp express_reason(:support, %{express_checkout: true}),
    do: "The flag is on; support are refused by the resource's policy."

  defp express_reason(_role, _flags), do: "The flag is off."

  defp declarative_notice(provider) do
    "#{provider} reads its whole state from docker/ at boot, so there is nothing to flip " <>
      "from here. Edit the file and restart the container."
  end

  defp unreachable_notice(provider, reason) do
    "#{provider} is not answering (#{inspect(reason)}). Run `docker compose up -d`."
  end
end
