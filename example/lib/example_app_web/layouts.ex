defmodule ExampleAppWeb.Layouts do
  @moduledoc """
  The one layout. The stylesheet is inline because a demo you can read in a
  single file beats a demo with a build step.
  """

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>ash_feature_flags playground</title>
        <style>
          <%= Phoenix.HTML.raw(stylesheet()) %>
        </style>
      </head>
      <body>
        {@inner_content}
        <script src="/js/phoenix/phoenix.js">
        </script>
        <script src="/js/live_view/phoenix_live_view.js">
        </script>
        <script>
          const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
          const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
            params: {_csrf_token: csrfToken}
          })
          liveSocket.connect()
          window.liveSocket = liveSocket
        </script>
      </body>
    </html>
    """
  end

  defp stylesheet do
    """
    :root {
      --bg: #f6f7f9;
      --panel: #ffffff;
      --border: #dfe3e8;
      --text: #16191d;
      --muted: #6b7280;
      --accent: #4f46e5;
      --on-bg: #dcfce7;
      --on-fg: #14532d;
      --off-bg: #f1f2f4;
      --off-fg: #6b7280;
      --warn-bg: #fef3c7;
      --warn-fg: #78350f;
      --err-bg: #fee2e2;
      --err-fg: #7f1d1d;
      --code: #eef0f3;
    }

    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #0f1115;
        --panel: #171a20;
        --border: #2a2f38;
        --text: #e7e9ec;
        --muted: #9aa2ae;
        --accent: #818cf8;
        --on-bg: #0f2e1d;
        --on-fg: #86efac;
        --off-bg: #1c2027;
        --off-fg: #8b93a0;
        --warn-bg: #3a2d0c;
        --warn-fg: #fcd34d;
        --err-bg: #3b1214;
        --err-fg: #fca5a5;
        --code: #1c2027;
      }
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font: 15px/1.5 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
    }

    code, .mono {
      font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
      font-size: 0.88em;
    }

    code {
      background: var(--code);
      padding: 0.1em 0.35em;
      border-radius: 4px;
    }

    .wrap { max-width: 1180px; margin: 0 auto; padding: 28px 20px 64px; }

    header.masthead { margin-bottom: 24px; }
    header.masthead h1 { margin: 0 0 6px; font-size: 22px; letter-spacing: -0.01em; }
    header.masthead p { margin: 0; color: var(--muted); max-width: 68ch; }

    .columns {
      display: grid;
      grid-template-columns: minmax(0, 360px) minmax(0, 1fr);
      gap: 20px;
      align-items: start;
    }

    @media (max-width: 900px) {
      .columns { grid-template-columns: minmax(0, 1fr); }
    }

    .panel {
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 10px;
      margin-bottom: 20px;
      overflow: hidden;
    }

    .panel > h2 {
      margin: 0;
      padding: 12px 16px;
      font-size: 12px;
      font-weight: 600;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      color: var(--muted);
      border-bottom: 1px solid var(--border);
    }

    .panel-body { padding: 16px; }
    .panel-body > p:first-child { margin-top: 0; }
    .panel-body > p:last-child { margin-bottom: 0; }

    .segmented { display: flex; flex-wrap: wrap; gap: 8px; }

    .segmented button {
      flex: 1 1 auto;
      padding: 9px 12px;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: transparent;
      color: var(--text);
      font: inherit;
      font-size: 14px;
      cursor: pointer;
      transition: border-color .12s, background .12s;
    }

    .segmented button:hover:not(:disabled) { border-color: var(--accent); }
    .segmented button[aria-pressed="true"] {
      border-color: var(--accent);
      background: color-mix(in srgb, var(--accent) 12%, transparent);
      font-weight: 600;
    }
    .segmented button:disabled { opacity: 0.45; cursor: not-allowed; }

    .hint { color: var(--muted); font-size: 13px; margin: 10px 0 0; }

    .flag { border-bottom: 1px solid var(--border); padding: 12px 16px; }
    .flag:last-child { border-bottom: 0; }
    .flag-top { display: flex; align-items: center; gap: 10px; }
    .flag-key { flex: 1; }
    .flag-why { color: var(--muted); font-size: 12.5px; margin-top: 4px; }

    .pill {
      display: inline-block;
      padding: 2px 9px;
      border-radius: 999px;
      font-size: 11px;
      font-weight: 700;
      letter-spacing: 0.06em;
      text-transform: uppercase;
    }
    .pill.on  { background: var(--on-bg);  color: var(--on-fg); }
    .pill.off { background: var(--off-bg); color: var(--off-fg); }

    .toggle {
      border: 1px solid var(--border);
      background: transparent;
      color: var(--text);
      border-radius: 6px;
      padding: 4px 10px;
      font: inherit;
      font-size: 12px;
      cursor: pointer;
    }
    .toggle:hover { border-color: var(--accent); }
    .toggle:disabled { opacity: 0.4; cursor: not-allowed; }

    .order { padding: 20px; }
    .order h3 { margin: 0 0 2px; font-size: 19px; }
    .order .ref { color: var(--muted); font-size: 13px; }

    .price { font-size: 30px; font-weight: 650; margin: 14px 0 2px; letter-spacing: -0.02em; }
    .price .was { font-size: 17px; font-weight: 400; color: var(--muted); text-decoration: line-through; margin-right: 10px; }

    .fields { margin: 18px 0 0; border-top: 1px solid var(--border); }
    .field { display: flex; gap: 14px; padding: 11px 0; border-bottom: 1px solid var(--border); }
    .field dt { flex: 0 0 150px; color: var(--muted); font-size: 13.5px; margin: 0; }
    .field dd { margin: 0; flex: 1; min-width: 0; }
    .field.hidden dd { color: var(--muted); font-style: italic; }
    .field .note { display: block; color: var(--muted); font-size: 12.5px; margin-top: 3px; font-style: normal; }

    .actions { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 20px; }

    .btn {
      padding: 10px 16px;
      border-radius: 8px;
      border: 1px solid transparent;
      background: var(--accent);
      color: #fff;
      font: inherit;
      font-weight: 600;
      cursor: pointer;
    }
    .btn:hover { filter: brightness(1.08); }
    .btn.ghost { background: transparent; border-color: var(--border); color: var(--text); }

    /* Not a flex row: these read as a sentence, and a <code> inside a flex
       container becomes its own item and breaks the line in the wrong place. */
    .withheld {
      flex: 1 1 100%;
      padding: 10px 14px;
      border: 1px dashed var(--border);
      border-radius: 8px;
      color: var(--muted);
      font-size: 13.5px;
      line-height: 1.55;
    }

    .banner { padding: 11px 14px; border-radius: 8px; font-size: 14px; margin-bottom: 14px; }
    .banner.ok   { background: var(--on-bg);   color: var(--on-fg); }
    .banner.warn { background: var(--warn-bg); color: var(--warn-fg); }
    .banner.err  { background: var(--err-bg);  color: var(--err-fg); }

    .legend { color: var(--muted); font-size: 13px; }
    .legend li { margin-bottom: 5px; }
    """
  end
end
