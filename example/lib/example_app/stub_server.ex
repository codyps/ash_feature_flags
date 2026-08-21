defmodule ExampleApp.StubServer do
  @moduledoc """
  A loopback stand-in for Flipt and flagd, so `mix demo --stub` works before
  you have Docker.

  **This is not Flipt and not flagd.** It implements just enough of their two
  wire protocols to answer the demo's five flags with the same rules the files
  in `docker/` express. Its purpose is to let you see
  `AshFeatureFlags.Provider.Flipt` and `AshFeatureFlags.Provider.OpenFeature`
  making real HTTP calls and parsing real responses, on a machine with nothing
  installed. When you run `docker compose up -d`, drop the `--stub` and the
  same provider code talks to the real services.

  Reading it is also the shortest description of what each provider expects
  back:

    * Flipt boolean: `POST /evaluate/v1/boolean` -> `{"enabled": true}`
    * Flipt variant: `POST /evaluate/v1/variant` -> `{"match": true, "variantKey": "..."}`
    * OFREP: `POST /ofrep/v1/evaluate/flags/:key` -> `{"value": true, "variant": "on"}`
  """

  use Plug.Router

  require Logger

  @flipt_port 18_080
  @ofrep_port 18_016

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  @doc "Starts both listeners. Returns the base urls to point providers at."
  @spec start() :: {:ok, %{flipt: String.t(), flagd: String.t()}} | {:error, term()}
  def start do
    with {:ok, _} <- start_listener(@flipt_port),
         {:ok, _} <- start_listener(@ofrep_port) do
      {:ok,
       %{
         flipt: "http://127.0.0.1:#{@flipt_port}",
         flagd: "http://127.0.0.1:#{@ofrep_port}"
       }}
    end
  end

  defp start_listener(port) do
    case Bandit.start_link(plug: __MODULE__, port: port, ip: {127, 0, 0, 1}, startup_log: false) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  ## Flipt

  post "/evaluate/v1/boolean" do
    %{"flagKey" => key} = conn.body_params
    context = conn.body_params["context"] || %{}
    entity_id = conn.body_params["entityId"]

    case evaluate(key, context, entity_id) do
      :unknown ->
        # Flipt 404s on an unknown flag; the provider turns that into an error,
        # which lands on the flag's declared default.
        send_json(conn, 404, %{"message" => "flag not found", "code" => 5})

      value ->
        send_json(conn, 200, %{
          "enabled" => value,
          "reason" => "MATCH_EVALUATION_REASON",
          "flagKey" => key
        })
    end
  end

  post "/evaluate/v1/variant" do
    %{"flagKey" => key} = conn.body_params
    context = conn.body_params["context"] || %{}
    entity_id = conn.body_params["entityId"]

    case evaluate(key, context, entity_id) do
      :unknown -> send_json(conn, 404, %{"message" => "flag not found"})
      true -> send_json(conn, 200, %{"match" => true, "variantKey" => "on"})
      false -> send_json(conn, 200, %{"match" => false})
    end
  end

  ## OFREP

  post "/ofrep/v1/evaluate/flags/:key" do
    context = conn.body_params["context"] || %{}
    targeting_key = context["targetingKey"]

    case evaluate(key, context, targeting_key) do
      :unknown ->
        send_json(conn, 404, %{
          "key" => key,
          "errorCode" => "FLAG_NOT_FOUND",
          "errorDetails" => "no such flag"
        })

      value ->
        send_json(conn, 200, %{
          "key" => key,
          "value" => value,
          "reason" => "TARGETING_MATCH",
          "variant" => if(value, do: "on", else: "off")
        })
    end
  end

  get "/health" do
    send_json(conn, 200, %{"status" => "ok"})
  end

  match _ do
    send_json(conn, 404, %{"error" => "not found"})
  end

  ## The rules — the same five flags as docker/flipt/features.yml and
  ## docker/flagd/flags.json, evaluated here in Elixir.

  defp evaluate("express-checkout", _context, _key), do: true
  defp evaluate("gift-wrapping", _context, _key), do: false
  defp evaluate("ml-scoring", _context, _key), do: false

  defp evaluate("fraud-tooling", context, _key) do
    # `roles` arrives as a comma-joined string, which is why Flipt uses
    # `contains` and flagd uses JsonLogic `in`.
    context |> Map.get("roles", "") |> String.split(",") |> Enum.member?("support")
  end

  defp evaluate("loyalty-pricing", _context, targeting_key) do
    :erlang.phash2({"loyalty-pricing", targeting_key || "anonymous"}, 100) < 50
  end

  defp evaluate(_key, _context, _targeting_key), do: :unknown

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
