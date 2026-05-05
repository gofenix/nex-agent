defmodule NexAgentConsole.Pages.Document do
  use Nex

  def render(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="UTF-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <title>{@title}</title>
        <link rel="stylesheet" href="/static/app.css" />
      </head>
      <body>
        <div class="console-frame">
          <header class="topbar">
            <a class="brand" href="/traces">NexAgent Trace</a>
            <span class="workspace mono">{Map.get(assigns, :workspace, "")}</span>
          </header>
          {raw(@inner_content)}
        </div>
      </body>
    </html>
    """
  end
end
