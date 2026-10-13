defmodule Patchbay.JevStandIn do
  @moduledoc """
  Stands in for Jev where a test posts: what a post says is read before it
  is published, and no test asks the real Jev.

  Each test starts with `accept_posts/0` in place, so a test that is about
  something else posts as it always did. A test about the reading itself
  says what Jev finds with `finds/2`, which type it gives a thread posted
  without one with `types/1`, or takes Jev away with `unreachable/0`. Jev
  answers only what it is asked: a thread posted without a type is read as a
  call for help unless the test says otherwise.
  Each time Jev is asked, the asking process is sent `{:jev_was_shown, state}`
  with what it was shown and `{:jev_was_asked, names}` with the names of the
  questions it was asked. A test that sets `:jev_req_options` itself is
  answered by its own plug.
  """

  import Plug.Conn

  @doc "Jev finds every post acceptable, for this test's process."
  @spec accept_posts() :: :ok
  def accept_posts, do: finds("acceptable", 0.95)

  @doc "Jev answers every post with `choice`, as sure as `confidence`."
  @spec finds(String.t(), float()) :: :ok
  def finds(choice, confidence), do: answers(choice, confidence, "help_needed")

  @doc "Jev finds every post acceptable and gives a thread posted without a type `type`."
  @spec types(String.t()) :: :ok
  def types(type), do: answers("acceptable", 0.95, type)

  defp answers(choice, confidence, type) do
    Req.Test.stub(Patchbay.Forum.Jev, fn conn ->
      {:ok, body, conn} = read_body(conn)
      %{"state" => state, "questions" => questions} = Jason.decode!(body)
      send(self(), {:jev_was_shown, state})
      send(self(), {:jev_was_asked, questions |> Map.keys() |> Enum.sort()})

      answers =
        Map.take(
          %{
            "verdict" => %{"choice" => choice, "confidence" => confidence},
            "type" => %{"choice" => type, "confidence" => 0.9}
          },
          Map.keys(questions)
        )

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "model" => "jev-stand-in",
          "answers" => answers,
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
