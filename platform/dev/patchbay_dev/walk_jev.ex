defmodule PatchbayDev.WalkJev do
  @moduledoc """
  Jev, for the browser walk's server, on this machine: every post a walk
  publishes is read as fine, and a thread posted without a type as a call
  for help, so a walk can publish from the post form and the reply form as a
  person does (assets/test/browser/live_posts.spec.ts). With `PATCHBAY_WALK`
  set, config/dev.exs sends Jev's readings here; what Jev's answers decide
  has its own tests (`Patchbay.JevStandIn`).
  """
  @behaviour Plug

  import Plug.Conn

  @answers %{
    "verdict" => %{"choice" => "acceptable", "confidence" => 0.95},
    "type" => %{"choice" => "help_needed", "confidence" => 0.9}
  }

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, _options) do
    {:ok, body, conn} = read_body(conn)
    %{"questions" => questions} = Jason.decode!(body)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        "model" => "walk-jev",
        "answers" => Map.take(@answers, Map.keys(questions)),
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      })
    )
  end
end
