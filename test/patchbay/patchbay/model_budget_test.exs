defmodule Patchbay.Patchbay.ModelBudgetTest do
  use Patchbay.DataCase, async: false

  require Ash.Query

  alias Patchbay.Patchbay, as: Domain

  alias Patchbay.Patchbay.{
    CandidateCache,
    Digest,
    Fixtures,
    InvocationRunner,
    RepairPlanner,
    RoomTimeline
  }

  @limits [:daily_model_calls, :room_daily_model_calls, :room_cooldown_seconds]

  setup do
    room = Domain.create_seeded_room!()

    revision =
      Fixtures.revision_attributes(room.id)
      |> Map.delete(:contract_sha256)
      |> Domain.create_tool_revision!()

    browser_session =
      Domain.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: Ash.UUID.generate(),
        user_agent_digest: Digest.sha256("test-agent"),
        webmcp_supported: true
      })

    Domain.observe_browser_session!(browser_session, %{
      observed_generation: revision.generation,
      observed_contracts: %{revision.name => revision.contract_sha256},
      webmcp_supported: true
    })

    CandidateCache.clear()

    on_exit(fn ->
      Enum.each(@limits, &Application.delete_env(:patchbay, &1))
      CandidateCache.clear()
    end)

    %{room: room, revision: revision, browser_session: browser_session}
  end

  test "the room cooldown refuses a second live generation and never calls the model", context do
    %{room: room} = context

    first = invoke_live!(context, "first uplift")
    assert first.effective_status == :awaiting_visible_state
    assert_received {:model_called, "first uplift"}

    refused = invoke_live!(context, "second uplift")

    assert refused.effective_status == :errored
    refute_received {:model_called, "second uplift"}

    assert refused.handler_reported_success == false
    assert refused.generated_candidate == nil
    assert refused.handler_result["error"] =~ "asked the model for a candidate moments ago"
    assert refused.handler_result["error"] =~ "Try again in"

    assert Domain.get_room_by_id!(room.id).candidate_markdown == nil

    assert Enum.any?(
             RoomTimeline.list!(room.id),
             &(&1.kind == :platform_error and &1.payload["failure"] == "MODEL_GENERATION_FAILED")
           )
  end

  test "the room cap refuses the call after its last one for the day", context do
    Application.put_env(:patchbay, :room_cooldown_seconds, 0)

    for index <- 1..30 do
      invocation = invoke_live!(context, "uplift #{index}")
      assert invocation.effective_status == :awaiting_visible_state
    end

    refused = invoke_live!(context, "uplift 31")

    assert refused.effective_status == :errored
    refute_received {:model_called, "uplift 31"}

    assert refused.handler_result["error"] =~
             "This room has used all 30 of its model calls for the last 24 hours."
  end

  test "the deployment ceiling refuses a room that is inside its own cap", context do
    Application.put_env(:patchbay, :room_cooldown_seconds, 0)
    Application.put_env(:patchbay, :daily_model_calls, 1)

    assert invoke_live!(context, "first uplift").effective_status == :awaiting_visible_state

    refused = invoke_live!(context, "second uplift")

    assert refused.effective_status == :errored
    refute_received {:model_called, "second uplift"}

    assert refused.handler_result["error"] =~
             "Patchbay has used all 1 of its model calls for the last 24 hours."
  end

  test "a repeated request is served from the cache during the cooldown", context do
    first = invoke_live!(context, "same instructions")
    assert first.effective_status == :awaiting_visible_state
    assert_received {:model_called, "same instructions"}

    repeated = invoke_live!(context, "same instructions")

    assert repeated.effective_status == :awaiting_visible_state
    refute_received {:model_called, "same instructions"}
    assert repeated.generated_candidate == first.generated_candidate

    assert repeated.handler_result["candidate_provenance"] ==
             first.handler_result["candidate_provenance"]
  end

  test "the demo fallback still answers when the limits refuse a live call", context do
    %{room: room, revision: revision, browser_session: browser_session} = context
    Application.put_env(:patchbay, :room_daily_model_calls, 0)

    invocation =
      InvocationRunner.invoke!(room, browser_session, revision, %{"instructions" => "uplift"},
        request_uuid: Ash.UUID.generate(),
        fallback: true
      )

    assert invocation.effective_status == :awaiting_visible_state
    assert invocation.handler_result["candidate_provenance"]["fallback_used"] == true
    assert invocation.handler_result["candidate_provenance"]["model"] == "patchbay-demo-fallback"
  end

  test "a fallback run does not spend the room's daily calls", context do
    %{room: room, revision: revision, browser_session: browser_session} = context
    Application.put_env(:patchbay, :room_cooldown_seconds, 0)
    Application.put_env(:patchbay, :room_daily_model_calls, 1)

    InvocationRunner.invoke!(room, browser_session, revision, %{"instructions" => "fallback run"},
      request_uuid: Ash.UUID.generate(),
      fallback: true
    )

    assert invoke_live!(context, "live run").effective_status == :awaiting_visible_state
    assert_received {:model_called, "live run"}
  end

  test "the repair plan is refused and never calls the model", context do
    %{room: room} = context
    failed = invoke_failed!(context, "repair me")
    Application.put_env(:patchbay, :room_daily_model_calls, 0)

    parent = self()

    request = fn _payload, _opts, _endpoint ->
      send(parent, :repair_model_called)
      {:ok, %{"id" => "resp_repair", "output_text" => Jason.encode!(Fixtures.repair_plan())}}
    end

    assert_raise ArgumentError,
                 ~r/This room has used all 0 of its model calls/,
                 fn -> RepairPlanner.propose!(failed, request: request) end

    refute_received :repair_model_called

    assert Domain.get_room_by_id!(room.id).status == :failed
    assert Domain.list_repair_proposals!(query: [filter: [room_id: room.id]]) == []
  end

  test "a live repair plan spends one of the room's daily calls", context do
    Application.put_env(:patchbay, :room_cooldown_seconds, 0)
    Application.put_env(:patchbay, :room_daily_model_calls, 1)

    failed = invoke_failed!(context, "repair me")
    parent = self()

    request = fn _payload, _opts, _endpoint ->
      send(parent, :repair_model_called)
      {:ok, %{"id" => "resp_repair", "output_text" => Jason.encode!(Fixtures.repair_plan())}}
    end

    assert RepairPlanner.propose!(failed, request: request).model_response_id == "resp_repair"
    assert_received :repair_model_called

    refused = invoke_live!(context, "uplift after repair")

    assert refused.effective_status == :errored

    assert refused.handler_result["error"] =~
             "This room has used all 1 of its model calls for the last 24 hours."
  end

  defp invoke_live!(context, instructions) do
    %{room: room, revision: revision, browser_session: browser_session} = context
    parent = self()

    generator = fn _source, _arguments ->
      send(parent, {:model_called, instructions})

      %{
        candidate_markdown: Fixtures.improved_markdown(),
        change_summary: ["clarified the workflow"],
        warnings: [],
        model: "gpt-5.6-terra",
        model_response_id: "resp_#{Digest.sha256(instructions)}",
        prompt_version: "patchbay-candidate-v1"
      }
    end

    InvocationRunner.invoke!(
      room,
      browser_session,
      revision,
      %{"instructions" => instructions},
      request_uuid: Ash.UUID.generate(),
      generator: generator
    )
  end

  defp invoke_failed!(context, instructions) do
    %{room: room, revision: revision, browser_session: browser_session} = context

    room
    |> InvocationRunner.invoke!(browser_session, revision, %{"instructions" => instructions},
      request_uuid: Ash.UUID.generate(),
      fallback: true
    )
    |> verify_visible!(room.id)
  end

  defp verify_visible!(invocation, room_id) do
    room = Domain.get_room_by_id!(room_id)

    InvocationRunner.verify!(invocation, %{
      "ui_revision" => room.ui_revision,
      "source" => %{"present" => true, "sha256" => room.source_sha256},
      "candidate" => %{
        "present" => is_binary(room.candidate_markdown),
        "sha256" => room.candidate_sha256
      }
    })
  end
end
