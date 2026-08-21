defmodule AshFeatureFlags.HTTP do
  @moduledoc """
  The tiny HTTP surface the network-backed providers need.

  Kept behind a behaviour for two reasons: `req` stays an optional dependency,
  and provider tests can pass a stub instead of standing up a server.

      feature_flags do
        provider {AshFeatureFlags.Provider.Flipt,
                  base_url: "http://flipt:8080",
                  http_client: MyApp.FakeHTTP}
      end
  """

  @type response :: %{status: non_neg_integer(), body: term()}

  @doc """
  Performs a JSON request, returning the decoded body.

  Implementations must not raise; return `{:error, reason}` on transport
  failure so the evaluator can apply the flag's `on_error` strategy.
  """
  @callback request(
              method :: :get | :post,
              url :: String.t(),
              headers :: [{String.t(), String.t()}],
              body :: map() | nil,
              opts :: keyword()
            ) :: {:ok, response()} | {:error, term()}

  @doc false
  def client(opts) do
    opts[:http_client] ||
      Application.get_env(:ash_feature_flags, :http_client, AshFeatureFlags.HTTP.Req)
  end

  @doc false
  def post_json(url, headers, body, opts) do
    client(opts).request(:post, url, headers, body, opts)
  end

  @doc false
  def get_json(url, headers, opts) do
    client(opts).request(:get, url, headers, nil, opts)
  end
end

defmodule AshFeatureFlags.HTTP.Req do
  @moduledoc """
  The default HTTP client, built on `Req`.

  Add `{:req, "~> 0.5"}` to your deps to use any of the network-backed
  providers. Options passed to the provider are forwarded to `Req`, so
  `receive_timeout`, `retry`, `connect_options` and friends all work:

      provider {AshFeatureFlags.Provider.Flipt,
                base_url: "http://flipt:8080",
                receive_timeout: 500,
                retry: false}

  The defaults are deliberately impatient — a flag lookup sits in the request
  path, so waiting 15 seconds for a dead flag server is worse than falling back
  to the flag's default.

  `req_module:` swaps in a `Req`-compatible module, which is mostly useful for
  proving the "req is not installed" path behaves.
  """

  @behaviour AshFeatureFlags.HTTP

  @req_options [
    :receive_timeout,
    :connect_options,
    :retry,
    :retry_delay,
    :max_retries,
    :pool_timeout,
    :finch,
    :plug
  ]

  @impl AshFeatureFlags.HTTP
  def request(method, url, headers, body, opts) do
    req = opts[:req_module] || Req

    if Code.ensure_loaded?(req) do
      do_request(req, method, url, headers, body, opts)
    else
      # Deliberately a distinguishable reason rather than a raise: this
      # function rescues, so a raise here would be flattened into the same
      # `{:error, _}` a network blip produces and a missing dependency would
      # look like an outage. `:missing_dependency` survives to the log line.
      {:error,
       {:missing_dependency, :req,
        "#{inspect(__MODULE__)} requires the `req` package. Add {:req, \"~> 0.5\"} to " <>
          "your dependencies, or configure a different `http_client:` on the provider."}}
    end
  end

  defp do_request(req, method, url, headers, body, opts) do
    request_opts =
      [
        method: method,
        url: url,
        headers: headers,
        receive_timeout: opts[:receive_timeout] || 2_000,
        retry: Keyword.get(opts, :retry, false)
      ]
      |> maybe_put_json(body)
      |> Keyword.merge(Keyword.take(opts, @req_options))

    case apply(req, :request, [request_opts]) do
      {:ok, %{status: status, body: body}} -> {:ok, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end

  defp maybe_put_json(opts, nil), do: opts
  defp maybe_put_json(opts, body), do: Keyword.put(opts, :json, body)
end
