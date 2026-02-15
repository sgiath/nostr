defmodule Nostr.Relay.Web.Page do
  @moduledoc false

  @spec html() :: binary()
  def html do
    """
    <!doctype html>
    <html lang=\"en\">
      <head>
        <meta charset=\"utf-8\" />
        <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
        <title>Nostr Relay</title>
        <style>
          body {
            font-family: Arial, sans-serif;
            margin: 2rem;
            background: #0b1020;
            color: #e5edf7;
          }

          h1 {
            font-size: 1.5rem;
          }

          p {
            color: #a7b4c7;
          }
        </style>
      </head>
      <body>
        <main>
          <h1>Nostr Relay</h1>
          <p>WebSocket relay is reachable at this endpoint.</p>
        </main>
      </body>
    </html>
    """
  end
end
