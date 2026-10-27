defmodule Patchbay.AnswerWatchTest do
  # The answer check's keys are application-wide, so this file runs alone.
  use Patchbay.DataCase, async: false
  use Oban.Testing, repo: Patchbay.Repo

  import Plug.Conn

  alias Patchbay.AnswerWatch
  alias Patchbay.AnswerWatch.{Answer, Ask, Questions, WeeklyRun}

  @question "Which crypto wallets work with Claude Code?"

  setup do
    old_watch = Application.fetch_env!(:patchbay, :answer_watch)
    old_openrouter = Application.fetch_env!(:patchbay, :openrouter)

    Application.put_env(
      :patchbay,
      :answer_watch,
      Keyword.put(old_watch, :openai_api_key, "test-key-never-sent")
    )

    Application.put_env(
      :patchbay,
      :openrouter,
      Keyword.put(old_openrouter, :api_key, "test-key-never-sent")
    )

    on_exit(fn ->
      Application.put_env(:patchbay, :answer_watch, old_watch)
      Application.put_env(:patchbay, :openrouter, old_openrouter)
    end)
  end

  test "the weekly start asks every tracked question of both engines" do
    assert :ok = perform_job(WeeklyRun, %{})

    asks = all_enqueued(worker: Ask)
    assert length(asks) == 2 * length(Questions.all())

    week = Date.utc_today() |> Date.beginning_of_week() |> Date.to_iso8601()
    assert Enum.all?(asks, &(&1.args["week"] == week))
  end

  test "ChatGPT's answer is written down with its sources, and a Patchbay link counts" do
    answers(%{
      "model" => "gpt-5.6-terra-2026-10-01",
      "output" => [
        %{"type" => "web_search_call"},
        %{
          "type" => "message",
          "content" => [
            %{
              "type" => "output_text",
              "text" => "The Agent Wallet Bench on Patchbay tests four wallets.",
              "annotations" => [
                %{"type" => "url_citation", "url" => "https://patchbay.help/wallet-bench"},
                %{"type" => "url_citation", "url" => "https://example.com/wallets"}
              ]
            }
          ]
        }
      ]
    })

    assert :ok = ask("chatgpt")

    [answer] = recorded()
    assert answer.engine == :chatgpt
    assert {answer.persona, answer.stage, answer.topic} == {:wallet_teams, :comparing, :wallets}

    assert answer.cited_urls == [
             "https://patchbay.help/wallet-bench",
             "https://example.com/wallets"
           ]

    assert {answer.patchbay_cited, answer.patchbay_mentioned} == {true, true}
  end

  test "Perplexity's answer is written down, and one that never names Patchbay counts as neither" do
    answers(%{
      "model" => "perplexity/sonar",
      "choices" => [
        %{
          "message" => %{
            "content" => "Coinbase and Privy both offer agent wallets.",
            "annotations" => [
              %{"type" => "url_citation", "url_citation" => %{"url" => "https://example.com/a"}}
            ]
          }
        }
      ]
    })

    assert :ok = ask("perplexity")

    [answer] = recorded()
    assert answer.engine == :perplexity
    assert answer.cited_urls == ["https://example.com/a"]
    assert {answer.patchbay_cited, answer.patchbay_mentioned} == {false, false}
  end

  test "an answer already recorded for the week is not asked for again" do
    week = Date.beginning_of_week(Date.utc_today())

    AnswerWatch.record_answer!(
      %{
        week: week,
        engine: :chatgpt,
        question: @question,
        persona: :wallet_teams,
        stage: :comparing,
        topic: :wallets,
        model: "gpt-5.6-terra",
        answer: "Recorded earlier.",
        cited_urls: [],
        patchbay_cited: false,
        patchbay_mentioned: false
      },
      authorize?: false
    )

    Req.Test.stub(AnswerWatch, fn _conn -> flunk("asked again") end)

    assert :ok = ask("chatgpt")
    assert [%{answer: "Recorded earlier."}] = recorded()
  end

  test "an engine without its key, or a question no longer tracked, ends the ask for good" do
    Application.put_env(
      :patchbay,
      :answer_watch,
      Keyword.put(Application.fetch_env!(:patchbay, :answer_watch), :openai_api_key, nil)
    )

    assert {:cancel, :api_key_missing} = ask("chatgpt")
    assert {:cancel, :no_longer_tracked} = ask("perplexity", "A question nobody tracks")
    assert recorded() == []
  end

  defp ask(engine, question \\ @question) do
    week = Date.utc_today() |> Date.beginning_of_week() |> Date.to_iso8601()
    perform_job(Ask, %{week: week, engine: engine, question: question})
  end

  defp answers(body) do
    Req.Test.stub(AnswerWatch, fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end)
  end

  # Reads back the test's own records.
  defp recorded, do: Ash.read!(Answer, authorize?: false)
end
