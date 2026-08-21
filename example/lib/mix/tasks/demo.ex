defmodule Mix.Tasks.Demo do
  @shortdoc "Runs the feature flag scenarios against one or more providers"

  @moduledoc """
  Runs an identical scenario matrix against each flag backend.

      mix demo                      # every provider it can reach
      mix demo --offline            # only the ones needing no service
      mix demo --stub               # all four, with Flipt/flagd stubbed locally
      mix demo --provider flipt     # just one
      mix demo -p static -p sqlite  # a few

  Providers: `static`, `sqlite`, `flipt`, `flagd`.

  `flipt` and `flagd` need the services in `docker-compose.yml`:

      docker compose up -d

  `--stub` instead points those two providers at a local loopback server that
  speaks their wire protocols (`ExampleApp.StubServer`), so you can watch the
  HTTP providers work before installing Docker. It is a stand-in, not the real
  services — use it to check the plumbing, then run the real thing.

  Exits non-zero if any check fails, so it works in CI.
  """

  use Mix.Task

  alias ExampleApp.{Demo, Providers, Report}

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [provider: :keep, offline: :boolean, stub: :boolean],
        aliases: [p: :provider]
      )

    Mix.Task.run("app.start")

    providers = providers_from(opts)
    stub_urls = maybe_start_stub(opts)

    Report.banner()

    tallies =
      Enum.map(providers, fn provider ->
        Demo.run(provider, base_url: stub_urls[provider])
      end)

    case Report.summary(tallies) do
      0 -> :ok
      _failed -> exit({:shutdown, 1})
    end
  end

  defp maybe_start_stub(opts) do
    if opts[:stub] do
      {:ok, urls} = ExampleApp.StubServer.start()
      Report.stub_notice(urls)
      %{flipt: urls.flipt, flagd: urls.flagd}
    else
      %{}
    end
  end

  defp providers_from(opts) do
    case Keyword.get_values(opts, :provider) do
      [] ->
        if opts[:offline], do: Providers.offline_names(), else: Providers.names()

      names ->
        Enum.map(names, &parse_provider/1)
    end
  end

  defp parse_provider(name) do
    known = Providers.names()
    atom = String.to_atom(name)

    if atom in known do
      atom
    else
      Mix.raise("Unknown provider #{inspect(name)}. Known: #{Enum.join(known, ", ")}")
    end
  end
end
