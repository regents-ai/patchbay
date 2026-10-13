defmodule Patchbay.JevStandIn do
  @moduledoc """
  Stands in for Jev where a test posts: what a post says is read before it
  is published, and no test asks the real Jev.

  Each test starts with `accept_posts/0` in place, so a test that is about
  something else posts as it always did. A test about the reading itself
  says what Jev finds with `finds/2`, or takes Jev away with `unreachable/0`.
  Each time Jev is asked, the asking process is sent `{:jev_was_shown, state}`
  with what it was shown. A test that sets `:jev_req_options` itself is
  answered by its own plug.
  """

  import Plug.Conn

  @doc "Jev finds every post acceptable, for this test's process."
  @spec accept_posts() :: :ok
  def accept_posts, do: finds("acceptable", 0.95)

  @doc "Jev answers every post with `choice`, as sure as `confidence`."
  @spec finds(String.t(), float()) :: :ok
  def finds(choice, confidence) do
    Req.Test.stub(Patchbay.Forum.Jev, fn conn ->
      {:ok, body, conn} = read_body(conn)
      send(self(), {:jev_was_shown, Jason.decode!(body)["state"]})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "model" => "jev-stand-in",
          "answers" => %{"verdict" => %{"choice" => choice, "confidence" => confidence}},
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        })
      )
    end)
  end

  @doc "Jev cannot be reached."
  @spec unreachable() :: :ok
  def unreachable do
    Req.Test.stub(Patchbay.Forum.Jev, &Req.Test.transport_error(&1, :econnrefused))
  end
end
