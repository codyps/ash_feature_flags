defmodule AshFeatureFlags.Provider.Flipt do
  @moduledoc """
  Evaluates flags against [Flipt](https://flipt.io)'s evaluation API.

      config :ash_feature_flags,
        provider: {AshFeatureFlags.Provider.Flipt,
                   base_url: "http://flipt:8080",
                   namespace: "default",
                   token: {:system, "FLIPT_TOKEN"}}

  ## Options

    * `:base_url` (required) — where Flipt lives, without a trailing path
    * `:namespace` — Flipt namespace, defaults to `"default"`
    * `:token` — a client token; a literal string, `{:system, "VAR"}`, or a
      0-arity function. Sent as `Authorization: Bearer`.
    * `:reference` — a Flipt [reference](https://docs.flipt.io/guides/user/using-references)
      (git-style branch of flag state), sent as the `reference` field
    * `:http_client` and any `Req` option (`:receive_timeout`, `:retry`, ...)

  ## How the context maps

  `POST /evaluate/v1/boolean` with:

      {
        "namespaceKey": "default",
        "flagKey": "new-checkout",
        "entityId": "user?id=8e...",
        "context": {"roles": "admin,billing", "tenant": "acme", ...}
      }

  `entityId` is the actor's `ash_authentication` subject when there is one,
  which is what makes Flipt's percentage rollouts stable per user. Everything
  in `AshFeatureFlags.Context.to_string_map/1` — roles, tenant, resource,
  action, public actor attributes and any `context` you passed — becomes
  segment-matchable properties.

  Multivariate flags go to `POST /evaluate/v1/variant` and read `variantKey`.
  """

  @behaviour AshFeatureFlags.Provider

  alias AshFeatureFlags.{Context, Flag, HTTP}

  @impl AshFeatureFlags.Provider
  def init(opts) do
    if opts[:base_url] do
      {:ok, opts}
    else
      {:error, "#{inspect(__MODULE__)} requires a `:base_url` option"}
    end
  end

  @impl AshFeatureFlags.Provider
  def enabled?(%Flag{} = flag, %Context{} = context, opts) do
    case evaluate("boolean", flag, context, opts) do
      {:ok, %{"enabled" => enabled}} when is_boolean(enabled) -> {:ok, enabled}
      {:ok, body} -> {:error, {:unexpected_response, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl AshFeatureFlags.Provider
  def variant(%Flag{} = flag, %Context{} = context, opts) do
    case evaluate("variant", flag, context, opts) do
      # Flipt reports `match: false` when no segment rule applied, in which
      # case there is no variant rather than an error.
      {:ok, %{"match" => false}} -> {:ok, nil}
      {:ok, %{"variantKey" => variant}} -> {:ok, variant}
      {:ok, body} -> {:error, {:unexpected_response, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp evaluate(kind, flag, context, opts) do
    with {:ok, base_url} <- fetch_base_url(opts) do
      url = base_url <> "/evaluate/v1/" <> kind

      body =
        %{
          "namespaceKey" => opts[:namespace] || "default",
          "flagKey" => Flag.key(flag),
          "entityId" => entity_id(context),
          "context" => Map.merge(Context.to_string_map(context), stringify(flag.context))
        }
        |> maybe_put("reference", opts[:reference])

      case HTTP.post_json(url, headers(opts), body, opts) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %{status: 404}} ->
          # Flipt 404s on unknown flags. Treating that as an error routes it
          # through `on_error`, so a flag you have not created yet falls back
          # to its declared default instead of exploding.
          {:error, {:flag_not_found, Flag.key(flag)}}

        {:ok, %{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fetch_base_url(opts) do
    case opts[:base_url] do
      nil -> {:error, "#{inspect(__MODULE__)} requires a `:base_url` option"}
      url -> {:ok, String.trim_trailing(url, "/")}
    end
  end

  # Flipt hashes this for percentage rollouts, so it must be stable per actor.
  # Anonymous requests get a constant, which means a 50% rollout is all-or-
  # nothing for logged-out traffic — deliberate, since the alternative is a
  # user seeing the feature flicker between page loads.
  defp entity_id(%Context{targeting_key: nil}), do: "anonymous"
  defp entity_id(%Context{targeting_key: key}), do: key

  defp headers(opts) do
    case token(opts[:token]) do
      nil -> []
      token -> [{"authorization", "Bearer " <> token}]
    end
  end

  defp token(nil), do: nil
  defp token({:system, var}), do: System.get_env(var)
  defp token(fun) when is_function(fun, 0), do: fun.()
  defp token(token) when is_binary(token), do: token

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_string(value)} end)
  end
end
