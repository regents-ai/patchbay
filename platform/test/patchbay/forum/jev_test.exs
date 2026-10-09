defmodule Patchbay.Forum.JevTest do
  # Jev's Decisions endpoint names its tokens input_tokens and output_tokens,
  # unlike the chat endpoint; a question closed without them goes unmeasured.
  use Patchbay.DataCase, async: false

  import Plug.Conn

  alias Patchbay.Assist.{ModelCall, ModelCalls}
  alias Patchbay.Forum.Jev

  setup do
    old_jev = Application.get_env(:patchbay, :jev_req_options)
    old_openrouter = Application.fetch_env!(:patchbay, :openrouter)

    Application.put_env(
      :patchbay,
      :openrouter,
      Keyword.put(old_openrouter, :api_key, "test-key-never-sent")
    )

    on_exit(fn ->
      Application.put_env(:patchbay, :jev_req_options, old_jev)
      Application.put_env(:patchbay, :openrouter, old_openrouter)
    end)
  end

  test "a question Jev answers is written down with the tokens it used" do
    Application.put_env(:patchbay, :jev_req_options,
      plug: fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "answers" => %{},
            "usage" => %{"input_tokens" => 120, "output_tokens" => 7}
          })
        )
      end
    )

    call = ModelCalls.ask(:read_report, Jev.model())
    assert {:ok, _body} = Jev.decide(%{}, %{}, call)

    # Reads back the test's own record.
    closed = Ash.get!(ModelCall, call.id, authorize?: false)
    assert {closed.prompt_tokens, closed.completion_tokens} == {120, 7}
  end
end
