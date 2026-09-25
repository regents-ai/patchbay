defmodule Patchbay.Assist.WorkTest do
  @moduledoc """
  A paid assist's run against a site's own MCP server: the tools are listed
  live, Jev picks one, it is called with the agent's own arguments, Jev
  reads the answer, and the run's record says what happened. What the site
  answers is data; only a tool on Patchbay's read-only list that the site
  also marks read-only is called, any other is suggested; and a run whose
  helper is away waits for a person.
  """

  use Patchbay.DataCase, async: false

  import Plug.Conn

  alias Patchbay.Assist
  alias Patchbay.Assist.Work
  alias Patchbay.Identity
  alias Patchbay.Payments

  @wallet "0x" <> String.duplicate("d", 40)

  setup do
    old_assist = Application.get_env(:patchbay, :assist)
    old_jev = Application.get_env(:patchbay, :jev_req_options)
    old_target = Application.get_env(:patchbay, :assist_target)
    old_listed = Application.fetch_env!(:patchbay, :assist_read_only_tools)
    old_key = System.get_env("OPENROUTER_API_KEY")
    Application.put_env(:patchbay, :assist, pay_to_address: @wallet)

    # The fixture site's tools Patchbay treats as checked read-only ones.
    Application.put_env(:patchbay, :assist_read_only_tools, %{
      "bookings.example.com" => ~w(find_table lookup book)
    })

    System.put_env("OPENROUTER_API_KEY", "test-key-never-sent")

    on_exit(fn ->
      Application.put_env(:patchbay, :assist, old_assist)
      Application.put_env(:patchbay, :jev_req_options, old_jev)
      Application.put_env(:patchbay, :assist_target, old_target)
      Application.put_env(:patchbay, :assist_read_only_tools, old_listed)

      if old_key,
        do: System.put_env("OPENROUTER_API_KEY", old_key),
        else: System.delete_env("OPENROUTER_API_KEY")
    end)

    :ok
  end

  test "a live MCP site: Jev picks the tool, the agent's arguments are used, the answer is read" do
    site = mcp_site(%{"find_table" => %{"ok" => true, "reference" => "R-42"}})

    run =
      paid_run(site,
        believed_calls: [%{"tool" => "find_table", "arguments" => %{"party" => 2}}]
      )

    jev(fn state, questions ->
      cond do
        Map.has_key?(questions, "tool") ->
          assert state["goal"] == run.goal
          assert state["tools_the_agent_believed_in"] == ["find_table"]
          refute Map.has_key?(state, "wallet_address")
          %{"tool" => %{"choice" => "find_table", "confidence" => 0.9}}

        Map.has_key?(questions, "verdict") ->
          assert state["tool"] == "find_table"
          assert state["tool_answer_written_by_the_site"] =~ "R-42"
          %{"verdict" => %{"choice" => "reached", "confidence" => 0.8}}
      end
    end)

    assert :ok = Work.run(run.id)

    # The worker's own reads of the run it worked on.
    {:ok, done} = Assist.get_run(run.id, authorize?: false)
    assert done.status == :finished
    assert done.outcome == :reached
    assert done.started_at
    assert done.finished_at

    called = Enum.find(done.steps, &(&1["tool"] == "find_table"))
    assert called["call"] == "made"
    assert called["arguments"] == %{"party" => 2}
    assert called["answer"] =~ "R-42"
    assert called["reading"] == %{"verdict" => "reached", "confidence" => 0.8, "by" => "jev"}
    assert Enum.all?(done.steps, &Map.has_key?(&1, "at"))

    # The site saw one call, with only the run's own request on it.
    assert [%{"method" => "tools/call", "params" => %{"name" => "find_table"}} = call] =
             calls(site, "tools/call")

    assert call["params"]["arguments"] == %{"party" => 2}
    refute Map.has_key?(seen_headers(site), "cookie")

    # A run picked up once is not picked up again.
    assert :ok = Work.run(run.id)
    {:ok, again} = Assist.get_run(run.id, authorize?: false)
    assert again.steps == done.steps
  end

  test "Jev's try-next moves to the next tool; a tool that changes things is suggested, not called" do
    site =
      mcp_site(
        %{"lookup" => %{"found" => false}},
        annotations: %{"delete_booking" => %{"destructiveHint" => true}}
      )

    run = paid_run(site, believed_calls: [])
    drafter(fn -> drafted(%{}) end)

    jev(fn state, questions ->
      cond do
        Map.has_key?(questions, "tool") and state["tools_already_tried"] == [] ->
          %{"tool" => %{"choice" => "lookup", "confidence" => 0.6}}

        Map.has_key?(questions, "tool") ->
          %{"tool" => %{"choice" => "delete_booking", "confidence" => 0.7}}

        true ->
          %{"verdict" => %{"choice" => "try_next", "confidence" => 0.9}}
      end
    end)

    assert :ok = Work.run(run.id)
    {:ok, done} = Assist.get_run(run.id, authorize?: false)
    assert done.status == :finished
    assert done.outcome == :suggested
    assert [%{"params" => %{"name" => "lookup"}}] = calls(site, "tools/call")
    suggested = Enum.find(done.steps, &(&1["tool"] == "delete_booking"))
    assert suggested["call"] == "suggested"
    assert suggested["note"] =~ "not called"
    assert suggested["answer"] == nil
  end

  test "a tool not on Patchbay's read-only list, or not marked read-only by the site, is suggested and never called" do
    for {name, marks} <- [
          # Marked read-only by the site, but Patchbay never checked it.
          {"count_tables", %{"readOnlyHint" => true}},
          # On the list, but the site does not say it only reads.
          {"lookup", %{}},
          # On the list, but the site says it destroys things too.
          {"book", %{"readOnlyHint" => true, "destructiveHint" => true}}
        ] do
      site = mcp_site(%{name => %{"ok" => true}}, annotations: %{name => marks})
      run = paid_run(site, believed_calls: [%{"tool" => name, "arguments" => %{}}])

      jev(fn _state, questions ->
        assert Map.has_key?(questions, "tool")
        %{"tool" => %{"choice" => name, "confidence" => 0.9}}
      end)

      assert :ok = Work.run(run.id)
      {:ok, done} = Assist.get_run(run.id, authorize?: false)
      assert {done.status, done.outcome} == {:finished, :suggested}
      assert calls(site, "tools/call") == []

      assert %{"call" => "suggested", "answer" => nil, "reading" => nil} =
               Enum.find(done.steps, &(&1["tool"] == name))
    end
  end

  test "sign-in, provider failure and an unreachable site each end the run honestly" do
    site = mcp_site(%{"book" => %{"error" => "please sign in"}})
    run = paid_run(site, believed_calls: [%{"tool" => "book", "arguments" => %{}}])

    jev(fn _state, questions ->
      if Map.has_key?(questions, "tool"),
        do: %{"tool" => %{"choice" => "book", "confidence" => 0.9}},
        else: %{"verdict" => %{"choice" => "needs_sign_in", "confidence" => 0.9}}
    end)

    assert :ok = Work.run(run.id)
    {:ok, done} = Assist.get_run(run.id, authorize?: false)
    assert {done.status, done.outcome} == {:finished, :needs_sign_in}

    # Jev's provider refuses: the payment stands and a person finishes it.
    away = paid_run(site, believed_calls: [])

    Application.put_env(:patchbay, :jev_req_options,
      plug: fn conn -> send_resp(conn, 402, "no credit") end
    )

    assert :ok = Work.run(away.id)
    {:ok, waiting} = Assist.get_run(away.id, authorize?: false)
    assert {waiting.status, waiting.outcome} == {:assessment_pending, :provider_unavailable}
    assert Enum.any?(waiting.steps, &(&1["note"] =~ "person at Patchbay"))

    # A site that resolves nowhere public is never connected to.
    private = paid_run(site, believed_calls: [])
    Application.put_env(:patchbay, :assist_target, resolve: fn _ -> [{10, 0, 0, 1}] end)
    assert :ok = Work.run(private.id)
    {:ok, unlisted} = Assist.get_run(private.id, authorize?: false)
    assert {unlisted.status, unlisted.outcome} == {:finished, :tools_unlisted}
    assert Enum.any?(unlisted.steps, &(&1["note"] =~ "public internet"))
  end

  test "a site whose tools live in its pages: the tool in its code is suggested, never called" do
    run = paid_run(mcp_site(%{}), believed_calls: [])
    Patchbay.PageSite.serve(%{"/mcp" => Patchbay.PageSite.with_tool("reserve_table")})
    drafter(fn -> drafted(%{"party" => 2}) end)

    jev(fn state, _questions ->
      assert state["goal"] == run.goal
      %{"tool" => %{"choice" => "reserve_table", "confidence" => 0.8}}
    end)

    assert :ok = Work.run(run.id)
    {:ok, done} = Assist.get_run(run.id, authorize?: false)
    assert {done.status, done.outcome} == {:finished, :suggested}
    assert Enum.any?(done.steps, &(&1["note"] =~ "Patchbay found 1 of them"))

    suggested = Enum.find(done.steps, &(&1["tool"] == "reserve_table"))
    assert suggested["arguments"] == %{"party" => 2}
    assert suggested["answer"] == nil

    # A site with nothing in its pages ends the run without a suggestion.
    empty = paid_run(mcp_site(%{}), believed_calls: [])
    Patchbay.PageSite.serve(%{"/mcp" => Patchbay.PageSite.without_tools()})
    assert :ok = Work.run(empty.id)
    {:ok, unlisted} = Assist.get_run(empty.id, authorize?: false)
    assert {unlisted.status, unlisted.outcome} == {:finished, :tools_unlisted}
    assert Enum.any?(unlisted.steps, &(&1["note"] =~ "no tools are written into its page"))
  end

  test "a run that waited on a person is handed back and finished, with nothing paid twice" do
    site = mcp_site(%{"lookup" => %{"found" => true}})
    run = paid_run(site, believed_calls: [])

    jev(fn _state, questions ->
      if Map.has_key?(questions, "tool"),
        do: %{"tool" => %{"choice" => "lookup", "confidence" => 0.9}},
        else: %{"verdict" => %{"choice" => "reached", "confidence" => 0.9}}
    end)

    # The drafting model is away: the run waits on a person, and nothing was called.
    drafter(fn -> {:error, {:http_status, 429}} end)
    assert :ok = Work.run(run.id)
    {:ok, waiting} = Assist.get_run(run.id, authorize?: false)
    assert {waiting.status, waiting.outcome} == {:assessment_pending, :provider_unavailable}
    assert calls(site, "tools/call") == []

    # The model is back, and a person hands the run to Patchbay again.
    drafter(fn -> drafted(%{"party" => 2}) end)
    assert {:ok, again} = Assist.rerun(run.id)
    assert {again.status, again.outcome, again.finished_at} == {:paid, nil, nil}
    assert List.last(again.steps)["note"] =~ "picked this up again"

    assert :ok = Work.run(run.id)
    {:ok, done} = Assist.get_run(run.id, authorize?: false)
    assert {done.status, done.outcome} == {:finished, :reached}
    assert Enum.take(done.steps, length(waiting.steps)) == waiting.steps

    assert [%{"params" => %{"name" => "lookup", "arguments" => %{"party" => 2}}}] =
             calls(site, "tools/call")

    # A run that is not waiting on a person is left as it is.
    assert {:error, %Ash.Error.Invalid{}} = Assist.rerun(run.id)
    {:ok, still} = Assist.get_run(run.id, authorize?: false)
    assert still.steps == done.steps
  end

  test "a site's answer is kept as data: a stray NUL byte neither kills nor empties the run" do
    site = mcp_site(%{"lookup" => "found\0it"})
    run = paid_run(site, believed_calls: [%{"tool" => "lookup", "arguments" => %{}}])

    jev(fn _state, questions ->
      if Map.has_key?(questions, "tool"),
        do: %{"tool" => %{"choice" => "lookup", "confidence" => 0.9}},
        else: %{"verdict" => %{"choice" => "reached", "confidence" => 0.9}}
    end)

    assert :ok = Work.run(run.id)
    {:ok, done} = Assist.get_run(run.id, authorize?: false)
    assert {done.status, done.outcome} == {:finished, :reached}
    assert Enum.find(done.steps, &(&1["tool"] == "lookup"))["answer"] =~ "found"
  end

  test "an error mid-run closes it as failed and keeps every step written before it" do
    site = mcp_site(%{"lookup" => %{"found" => true}})
    run = paid_run(site, believed_calls: [%{"tool" => "lookup", "arguments" => %{}}])

    jev(fn _state, questions ->
      if Map.has_key?(questions, "tool"),
        do: %{"tool" => %{"choice" => "lookup", "confidence" => 0.9}},
        else: raise("jev fixture fell over")
    end)

    assert :ok = Work.run(run.id)
    {:ok, failed} = Assist.get_run(run.id, authorize?: false)
    assert {failed.status, failed.outcome} == {:failed, nil}
    assert Enum.any?(failed.steps, &(&1["note"] =~ "lists 1 tools"))
    assert Enum.any?(failed.steps, &(&1["note"] =~ "hit an error"))
  end

  test "a restart marks the runs that were open as failed; a lost worker closes its own" do
    site = mcp_site(%{})
    run = paid_run(site, believed_calls: [])
    {:ok, running} = Assist.start_run(run, authorize?: false)
    assert running.status == :running

    assert :ok = Assist.interrupt_open_runs()
    {:ok, failed} = Assist.get_run(run.id, authorize?: false)
    assert failed.status == :failed
    assert failed.finished_at

    # A run already answered is left as it is.
    assert :ok = Assist.interrupt_run(run.id)
    {:ok, still} = Assist.get_run(run.id, authorize?: false)
    assert still.finished_at == failed.finished_at

    # A run that was never picked up is closed too, by the runner that lost it.
    waiting = paid_run(site, believed_calls: [])
    assert :ok = Assist.interrupt_run(waiting.id)
    {:ok, closed} = Assist.get_run(waiting.id, authorize?: false)
    assert closed.status == :failed
  end

  test "one open run per payer is the database's rule, not only the door's" do
    site = mcp_site(%{})
    payer = payer()
    first = paid_run(site, payer: payer, believed_calls: [])

    {:ok, intent} = Payments.prepare_jev_assist(%{request: request([])}, actor: payer)
    {:ok, settled} = Ash.update(intent, %{}, action: :mark_settled, actor: payer)

    assert {:error, %Ash.Error.Invalid{}} =
             Assist.open_run(%{intent: settled, browser_session_id: nil}, actor: payer)

    # Once the first has answered, the same payment opens its run.
    {:ok, running} = Assist.start_run(first, authorize?: false)

    {:ok, _done} =
      Assist.finish_run(running, %{status: :finished, outcome: :reached}, authorize?: false)

    assert {:ok, _second} =
             Assist.open_run(%{intent: settled, browser_session_id: nil}, actor: payer)
  end

  # A paid, opened run for a fresh profile, pointed at the fixture site.
  defp paid_run(site, opts) do
    payer = Keyword.get_lazy(opts, :payer, &payer/0)
    request = request(Keyword.fetch!(opts, :believed_calls))

    {:ok, intent} = Payments.prepare_jev_assist(%{request: request}, actor: payer)
    {:ok, settled} = Ash.update(intent, %{}, action: :mark_settled, actor: payer)
    {:ok, run} = Assist.open_run(%{intent: settled, browser_session_id: nil}, actor: payer)

    # The site's name resolves to a public address, and the calls to it are
    # answered by the fixture in this process.
    Application.put_env(:patchbay, :assist_target,
      resolve: fn "bookings.example.com" -> [{93, 184, 216, 34}] end,
      req_options: [plug: site.plug]
    )

    run
  end

  defp payer do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:work-#{Ecto.UUID.generate()}",
      wallet_address: "0x" <> String.duplicate("a", 40)
    })
  end

  defp request(believed_calls) do
    %{
      "goal" => "Book the 9am table for two on Friday",
      "site_url" => "https://bookings.example.com/mcp",
      "sign_in" => "unknown",
      "expected_result" => "A confirmation with a booking reference",
      "believed_calls" => believed_calls
    }
  end

  # The drafting model on OpenRouter, answered by `answer.()`; the request
  # is checked to be the one the drafter is meant to send.
  defp drafter(answer) do
    Application.put_env(:patchbay, :assist_model_options,
      request: fn payload, _opts, url ->
        assert url == "https://openrouter.ai/api/v1/chat/completions"
        assert payload.model == "openai/gpt-5.6-terra"
        assert payload.response_format.json_schema.strict
        assert [%{role: "system"}, %{role: "user"}] = payload.messages
        answer.()
      end
    )

    on_exit(fn -> Application.delete_env(:patchbay, :assist_model_options) end)
  end

  defp drafted(arguments) do
    content = Jason.encode!(%{"arguments_json" => Jason.encode!(arguments)})
    {:ok, %{"choices" => [%{"message" => %{"content" => content}}]}}
  end

  # Jev's Decisions endpoint, answered by `answer.(state, questions)`.
  defp jev(answer) do
    Application.put_env(:patchbay, :jev_req_options,
      plug: fn conn ->
        {:ok, body, conn} = read_body(conn)
        %{"state" => state, "questions" => questions} = Jason.decode!(body)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{"model" => "jev-test", "answers" => answer.(state, questions)})
        )
      end
    )
  end

  # A site's MCP server: lists `tools`, each marked read-only unless
  # `annotations` names other marks for it, and answers each call with its
  # canned result. Everything it receives is kept for the test to read.
  defp mcp_site(results, opts \\ []) do
    annotations = Keyword.get(opts, :annotations, %{})
    seen = start_supervised!({Agent, fn -> [] end}, id: make_ref())

    tools =
      results
      |> Map.keys()
      |> Kernel.++(Map.keys(annotations))
      |> Enum.uniq()
      |> Enum.map(fn name ->
        %{
          "name" => name,
          "description" => "The #{name} tool.",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{"party" => %{"type" => "integer"}}
          },
          "annotations" => Map.get(annotations, name, %{"readOnlyHint" => true})
        }
      end)

    plug = fn conn ->
      {:ok, body, conn} = read_body(conn)
      message = Jason.decode!(body)
      Agent.update(seen, &[{message, conn.req_headers} | &1])

      result =
        case message do
          %{"method" => "initialize"} ->
            %{
              "protocolVersion" => "2025-06-18",
              "capabilities" => %{"tools" => %{}},
              "serverInfo" => %{"name" => "fixture"}
            }

          %{"method" => "tools/list"} ->
            %{"tools" => tools}

          %{"method" => "tools/call", "params" => %{"name" => name}} ->
            %{"content" => [%{"type" => "text", "text" => canned(Map.fetch!(results, name))}]}

          _notification ->
            nil
        end

      case {message["id"], result} do
        {nil, _} ->
          send_resp(conn, 202, "")

        {id, result} ->
          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("mcp-session-id", "fixture-session")
          |> send_resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
      end
    end

    %{plug: plug, seen: seen}
  end

  defp canned(text) when is_binary(text), do: text
  defp canned(result), do: Jason.encode!(result)

  defp calls(site, method) do
    site.seen
    |> Agent.get(&Enum.reverse/1)
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(&(&1["method"] == method))
  end

  defp seen_headers(site) do
    site.seen |> Agent.get(&Enum.reverse/1) |> Enum.flat_map(&elem(&1, 1)) |> Map.new()
  end
end
