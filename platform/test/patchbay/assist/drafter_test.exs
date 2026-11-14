defmodule Patchbay.Assist.DrafterTest do
  @moduledoc """
  The drafting model behind an assist, on NEAR AI Cloud: the request goes to
  the configured address and model, the answer is read for its arguments,
  and the question's record keeps the provider, the model, the answer's id,
  the provider's request id and the tokens it used. A refused request is
  written down as failed, as before. `PATCHBAY_DRAFTER_PROVIDER` chooses the
  provider at boot, and production with NEAR AI chosen and no key stops.
  """

  use Patchbay.DataCase, async: false

  import Patchbay.AssistFixtures, only: [browser_run: 0]

  alias Patchbay.Assist.Drafter
  alias Patchbay.Assist.ModelCall

  @near_ai [
    provider: "near_ai",
    url: "https://cloud-api.near.ai/v1/chat/completions",
    model: "z-ai/glm-5.3-flash",
    api_key: "test-key-never-sent",
    effort: %{reasoning_effort: "low"}
  ]

  @input %{
    tool: "find_table",
    description: "Finds a table.",
    input_schema: %{"type" => "object", "properties" => %{"party" => %{"type" => "integer"}}},
    goal: "Book the 9am table for two on Friday",
    what_went_wrong: nil
  }

  setup do
    old = Application.fetch_env!(:patchbay, :drafter)
    Application.put_env(:patchbay, :drafter, @near_ai)
    on_exit(fn -> Application.put_env(:patchbay, :drafter, old) end)
    %{run: browser_run()}
  end

  test "a NEAR AI answer is read, and the draft's record keeps model, ids and usage", %{run: run} do
    test = self()

    Req.Test.stub(Drafter, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:asked, conn.host, conn.request_path, Jason.decode!(body)})

      content = Jason.encode!(%{"arguments_json" => Jason.encode!(%{"party" => 2})})

      conn
      |> Plug.Conn.put_resp_header("x-request-id", "req-7f3a")
      |> Req.Test.json(%{
        "id" => "f47b4647911249f7a94468f6c2b95832",
        "object" => "chat.completion",
        "model" => "z-ai/glm-5.3-flash",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => content,
              "reasoning_content" => "Two people."
            },
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 311,
          "completion_tokens" => 24,
          "completion_tokens_details" => %{"reasoning_tokens" => 9},
          "total_tokens" => 335
        }
      })
    end)

    assert Drafter.draft(@input, run.id) == {:ok, %{"party" => 2}}

    assert_received {:asked, "cloud-api.near.ai", "/v1/chat/completions", payload}
    assert payload["model"] == "z-ai/glm-5.3-flash"
    assert payload["reasoning_effort"] == "low"
    refute Map.has_key?(payload, "reasoning")
    assert payload["response_format"]["json_schema"]["strict"]

    assert [call] = Ash.read!(ModelCall, authorize?: false)

    assert %{
             assist_run_id: run_id,
             purpose: :draft_arguments,
             outcome: :answered,
             provider: "near_ai",
             model: "z-ai/glm-5.3-flash",
             response_id: "f47b4647911249f7a94468f6c2b95832",
             request_id: "req-7f3a",
             prompt_tokens: 311,
             completion_tokens: 24
           } = call

    assert run_id == run.id
  end

  test "a refused request is failed, as any provider's refusal is", %{run: run} do
    Req.Test.stub(Drafter, fn conn ->
      conn
      |> Plug.Conn.put_status(402)
      |> Req.Test.json(%{"error" => %{"message" => "Insufficient credits"}})
    end)

    assert Drafter.draft(@input, run.id) == {:error, {:http_status, 402}}

    assert [%{outcome: :failed, provider: "near_ai", response_id: nil, request_id: nil}] =
             Ash.read!(ModelCall, authorize?: false)
  end

  test "an answer that holds no arguments is unusable", %{run: run} do
    Req.Test.stub(Drafter, fn conn ->
      Req.Test.json(conn, %{"id" => "x", "choices" => [%{"message" => %{"content" => "hi"}}]})
    end)

    assert Drafter.draft(@input, run.id) == {:error, :response_shape_invalid}
    assert [%{outcome: :answered, response_id: "x"}] = Ash.read!(ModelCall, authorize?: false)
  end

  describe "PATCHBAY_DRAFTER_PROVIDER" do
    setup do
      on_exit(fn -> System.delete_env("PATCHBAY_DRAFTER_PROVIDER") end)
    end

    test "near_ai sets NEAR AI's address, model and key name; unset stays on OpenRouter" do
      System.put_env("PATCHBAY_DRAFTER_PROVIDER", "near_ai")
      near = drafter_setting(:test)
      assert near[:provider] == "near_ai"
      assert near[:url] == "https://cloud-api.near.ai/v1/chat/completions"
      assert near[:model] == "z-ai/glm-5.3-flash"
      assert near[:api_key] == System.get_env("NEAR_AI_API_KEY")

      System.delete_env("PATCHBAY_DRAFTER_PROVIDER")
      assert drafter_setting(:test)[:provider] == "openrouter"
    end

    test "production with near_ai chosen and no NEAR_AI_API_KEY refuses to boot" do
      System.put_env("PATCHBAY_DRAFTER_PROVIDER", "near_ai")
      refute System.get_env("NEAR_AI_API_KEY")

      assert_raise RuntimeError, ~r/NEAR_AI_API_KEY must be set/, fn ->
        drafter_setting(:prod)
      end
    end
  end

  defp drafter_setting(env) do
    "config/runtime.exs"
    |> Config.Reader.read!(env: env)
    |> Keyword.fetch!(:patchbay)
    |> Keyword.fetch!(:drafter)
  end
end
