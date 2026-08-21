defmodule ExampleApp.Report do
  @moduledoc false

  alias ExampleApp.Providers

  @width 78

  def banner do
    IO.puts("")
    IO.puts(bold("AshFeatureFlags — the same resource, four flag backends"))

    IO.puts(
      dim("""
      One `feature_flags` block, one set of policies, four providers. If the
      tables below match, nothing in the application had to know which backend
      it was talking to.
      """)
    )
  end

  def stub_notice(urls) do
    IO.puts("")

    IO.puts(
      yellow("  --stub: ") <>
        dim(
          "Flipt and flagd are being stood in for by ExampleApp.StubServer " <>
            "(#{urls.flipt}, #{urls.flagd}).\n" <>
            "          It speaks their wire protocols but is not the real thing — " <>
            "run `docker compose up -d` and drop --stub for that."
        )
    )
  end

  def heading(provider) do
    IO.puts("")
    IO.puts(bold("── " <> Providers.label(provider) <> " " <> String.duplicate("─", 8)))
  end

  def section(title) do
    IO.puts("")
    IO.puts("  " <> underline(title))
  end

  def note(text) do
    IO.puts("  " <> dim(text))
  end

  def unreachable(provider, reason) do
    IO.puts("")
    IO.puts("  " <> yellow("service not reachable") <> " — " <> dim(inspect(reason)))
    IO.puts("")

    IO.puts("""
      Start it with:

          cd example && docker compose up -d #{compose_service(provider)}

      ...then run this again. Everything else in the demo works without Docker:

          mix demo --offline
    """)
  end

  def results(results) do
    Enum.each(results, fn
      {:section, title} -> section(title)
      {:note, text} -> note(text)
      {:check, label, why, ok?, actual} -> check_line(label, why, ok?, actual)
    end)
  end

  defp check_line(label, why, ok?, actual) do
    mark = if ok?, do: green("✓"), else: red("✗")

    IO.puts("  #{mark} #{pad(label)} #{dim(why)}")

    unless ok? do
      IO.puts("      " <> red("got: " <> actual))
    end
  end

  def summary(tallies) do
    passed = tallies |> Enum.map(&elem(&1, 0)) |> Enum.sum()
    failed = tallies |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    IO.puts("")
    IO.puts(String.duplicate("─", @width))

    line = "#{passed + failed} checks · #{passed} passed · #{failed} failed"

    IO.puts(if failed == 0, do: green(bold(line)), else: red(bold(line)))
    IO.puts("")

    failed
  end

  defp compose_service(:flipt), do: "flipt"
  defp compose_service(:flagd), do: "flagd"
  defp compose_service(_), do: ""

  defp pad(label) do
    label = String.slice(label, 0, 52)
    label <> String.duplicate(" ", max(0, 52 - String.length(label)))
  end

  defp bold(text), do: IO.ANSI.bright() <> text <> IO.ANSI.reset()
  defp dim(text), do: IO.ANSI.faint() <> text <> IO.ANSI.reset()
  defp underline(text), do: IO.ANSI.underline() <> text <> IO.ANSI.reset()
  defp green(text), do: IO.ANSI.green() <> text <> IO.ANSI.reset()
  defp red(text), do: IO.ANSI.red() <> text <> IO.ANSI.reset()
  defp yellow(text), do: IO.ANSI.yellow() <> text <> IO.ANSI.reset()
end
