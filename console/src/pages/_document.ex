defmodule NexAgentConsole.Pages.Document do
  use Nex

  def render(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="zh-CN">
      <head>
        <meta charset="UTF-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <title>{@title}</title>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
        <link href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,500;9..144,700&family=Manrope:wght@400;500;700;800&display=swap" rel="stylesheet" />
        <link rel="stylesheet" href="/static/app.css" />
        <script src="https://unpkg.com/htmx.org@2.0.4"></script>
      </head>
      <body>
        {raw(@inner_content)}

        <script>
          (function () {
            const connect = function () {
              const source = new EventSource("/api/admin/events");

              source.addEventListener("admin-event", function (evt) {
                let payload = {};

                try {
                  payload = JSON.parse(evt.data);
                } catch (_err) {
                  payload = { summary: evt.data };
                }

                const liveSummary = document.querySelector("[data-live-summary]");
                if (liveSummary && payload.summary) {
                  liveSummary.textContent = payload.summary;
                }

                document.body.dispatchEvent(
                  new CustomEvent("admin-event", {
                    bubbles: true,
                    detail: payload
                  })
                );
              });

              source.onerror = function () {
                window.setTimeout(connect, 1500);
                source.close();
              };
            };

            const connectWhenReady = function () {
              const panelSlot = document.querySelector(".panel-slot");

              if (!panelSlot) {
                connect();
                return;
              }

              let started = false;

              const start = function () {
                if (started) return;
                started = true;
                document.body.removeEventListener("htmx:afterSwap", onSwap);
                window.clearTimeout(fallbackTimer);
                connect();
              };

              const onSwap = function (evt) {
                if (evt.target === panelSlot || panelSlot.contains(evt.target)) {
                  start();
                }
              };

              document.body.addEventListener("htmx:afterSwap", onSwap);
              const fallbackTimer = window.setTimeout(start, 1200);
            };

            if (document.readyState === "loading") {
              document.addEventListener("DOMContentLoaded", connectWhenReady, { once: true });
            } else {
              connectWhenReady();
            }
          })();
        </script>
      </body>
    </html>
    """
  end
end
