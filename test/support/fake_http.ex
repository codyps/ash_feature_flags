defmodule AshFeatureFlags.Test.FakeHTTP do
  @moduledoc """
  Records requests and replays canned responses, so the HTTP providers can be
  tested without a Flipt or flagd instance.

      FakeHTTP.stub(fn :post, url, _headers, body, _opts ->
        {:ok, %{status: 200, body: %{"enabled" => true}}}
      end)
  """

  @behaviour AshFeatureFlags.HTTP

  @impl AshFeatureFlags.HTTP
  def request(method, url, headers, body, opts) do
    Process.put(:fake_http_last_request, %{
      method: method,
      url: url,
      headers: headers,
      body: body,
      opts: opts
    })

    case Process.get(:fake_http_stub) do
      nil -> {:error, :no_stub_configured}
      fun -> fun.(method, url, headers, body, opts)
    end
  end

  @doc "Installs a response function for the current process."
  def stub(fun) when is_function(fun, 5), do: Process.put(:fake_http_stub, fun)

  @doc "Always answers with this status and body."
  def stub(status, body) do
    stub(fn _method, _url, _headers, _body, _opts -> {:ok, %{status: status, body: body}} end)
  end

  @doc "The last request made from this process."
  def last_request, do: Process.get(:fake_http_last_request)
end
