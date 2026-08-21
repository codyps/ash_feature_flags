defmodule AshFeatureFlags.Provider.OpenFeature do
  @moduledoc """
  Evaluates flags over OFREP, the OpenFeature Remote Evaluation Protocol.

  OFREP is the vendor-neutral HTTP API that OpenFeature-compatible servers
  speak — [flagd](https://flagd.dev), GO Feature Flag, Flipt's OFREP endpoint,
  Unleash's OFREP edge, and others. If your flag server offers an OFREP
  endpoint, this provider talks to it without any vendor SDK.

      config :ash_feature_flags,
        provider: {AshFeatureFlags.Provider.OpenFeature,
                   base_url: "http://flagd:8016"}

  ## Options

    * `:base_url` (required) — the OFREP host. `/ofrep/v1/evaluate/flags/:key`
      is appended; override the prefix with `:path_prefix`.
    * `:path_prefix` — defaults to `"/ofrep/v1/evaluate/flags"`
    * `:headers` — extra headers, e.g. `[{"x-api-key", "..."}]`
    * `:token` — bearer token; string, `{:system, "VAR"}` or 0-arity function
    * `:http_client` and any `Req` option

  ## Using an in-process OpenFeature SDK instead

  If you already run the Elixir OpenFeature SDK, point this provider at it and
  no HTTP call is made:

      provider {AshFeatureFlags.Provider.OpenFeature, client: OpenFeature.get_client()}

  Anything implementing `get_boolean_value/3` and `get_string_value/3` works,
  which also makes this easy to stub.

  ## How the context maps

  OFREP takes an evaluation context with a `targetingKey`:

      POST /ofrep/v1/evaluate/flags/new-checkout
      {"context": {"targetingKey": "user?id=8e...", "roles": "admin", ...}}

  The response's `value` is used directly for booleans, and `variant` for
  multivariate flags. A 404 or `errorCode: "FLAG_NOT_FOUND"` is reported as an
  error, so an unknown flag falls back to its declared default rather than
  silently reading as off.
  """

  @behaviour AshFeatureFlags.Provider

  alias AshFeatureFlags.{Context, Flag, HTTP}

  @default_prefix "/ofrep/v1/evaluate/flags"

  @impl AshFeatureFlags.Provider
  def init(opts) do
    if opts[:base_url] || opts[:client] do
      {:ok, opts}
    else
      {:error, "#{inspect(__MODULE__)} requires either a `:base_url` or a `:client` option"}
    end
  end

  @impl AshFeatureFlags.Provider
  def enabled?(%Flag{} = flag, %Context{} = context, opts) do
    case opts[:client] do
      nil ->
        case evaluate(flag, context, opts) do
          {:ok, %{"value" => value}} when is_boolean(value) -> {:ok, value}
          {:ok, %{"value" => value}} when is_binary(value) -> {:ok, value not in ["", "off"]}
          {:ok, body} -> {:error, {:unexpected_response, body}}
          {:error, reason} -> {:error, reason}
        end

      client ->
        {:ok, call_sdk(client, :get_boolean_value, flag, context, flag.default)}
    end
  end

  @impl AshFeatureFlags.Provider
  def variant(%Flag{} = flag, %Context{} = context, opts) do
    case opts[:client] do
      nil ->
        case evaluate(flag, context, opts) do
          {:ok, %{"variant" => variant}} -> {:ok, variant}
          {:ok, %{"value" => value}} when is_binary(value) -> {:ok, value}
          {:ok, body} -> {:error, {:unexpected_response, body}}
          {:error, reason} -> {:error, reason}
        end

      client ->
        {:ok, call_sdk(client, :get_string_value, flag, context, nil)}
    end
  end

  defp evaluate(flag, context, opts) do
    with {:ok, base_url} <- fetch_base_url(opts) do
      prefix = opts[:path_prefix] || @default_prefix
      url = base_url <> prefix <> "/" <> URI.encode(Flag.key(flag))
      body = %{"context" => evaluation_context(flag, context)}

      case HTTP.post_json(url, headers(opts), body, opts) do
        {:ok, %{status: status, body: %{"errorCode" => code} = body}} when status in 200..299 ->
          {:error, {:ofrep_error, code, body["errorDetails"]}}

        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %{status: 404, body: body}} ->
          {:error, {:flag_not_found, Flag.key(flag), body}}

        {:ok, %{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp evaluation_context(flag, context) do
    context
    |> Context.to_string_map()
    |> Map.merge(Map.new(flag.context, fn {k, v} -> {to_string(k), v} end))
    |> Map.put("targetingKey", context.targeting_key || "anonymous")
  end

  defp call_sdk(client, function, flag, context, default) do
    apply(client, function, [Flag.key(flag), default, evaluation_context(flag, context)])
  end

  defp fetch_base_url(opts) do
    case opts[:base_url] do
      nil -> {:error, "#{inspect(__MODULE__)} requires a `:base_url` option"}
      url -> {:ok, String.trim_trailing(url, "/")}
    end
  end

  defp headers(opts) do
    extra = opts[:headers] || []

    case token(opts[:token]) do
      nil -> extra
      token -> [{"authorization", "Bearer " <> token} | extra]
    end
  end

  defp token(nil), do: nil
  defp token({:system, var}), do: System.get_env(var)
  defp token(fun) when is_function(fun, 0), do: fun.()
  defp token(token) when is_binary(token), do: token
end
