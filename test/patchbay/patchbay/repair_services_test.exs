defmodule Patchbay.Patchbay.RepairServicesTest do
  use Patchbay.DataCase, async: false

  require Ash.Query

  alias Elixir.Patchbay.Patchbay

  alias Elixir.Patchbay.Patchbay.{
    CandidateCache,
    CandidateGenerator,
    CanaryRunner,
    DemoReset,
    Digest,
    Fixtures,
    InvocationRunner,
    RepairApprovalService,
    RepairDSL,
    RepairPlanner,
    RoomTimeline,
    ToolRevision
  }

  alias Elixir.Patchbay.Patchbay.OpenAI.{Client, Prompts}

  setup do
    room = Patchbay.create_seeded_room!("room-#{System.unique_integer([:positive])}")

    revision = seeded_revision!(room)

    browser_session =
      Patchbay.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: Ash.UUID.generate(),
        user_agent_digest: Digest.sha256("test-agent"),
        webmcp_supported: true
      })

    Patchbay.observe_browser_session!(browser_session, %{
      observed_generation: revision.generation,
      observed_contracts: %{revision.name => revision.contract_sha256},
      webmcp_supported: true
    })

    CandidateCache.clear()

    %{room: room, revision: revision, browser_session: browser_session}
  end

  test "repair DSL is exact and rejects executable or unknown shapes" do
    valid = Fixtures.repair_plan()
    assert {:ok, parsed} = RepairDSL.parse(valid)
    assert parsed.handler_adapter == :apply_candidate_to_editor

    assert {:error, _} = RepairDSL.parse(Map.put(valid, "unexpected", true))

    assert {:error, _} =
             RepairDSL.parse(
               Map.put(valid, "description_replacement", "<script>alert(1)</script>")
             )

    assert {:error, _} = RepairDSL.parse(Map.put(valid, "handler_adapter", "run_javascript"))
  end

  test "prompt bytes are pinned so the model contract cannot drift silently" do
    assert Digest.sha256(Prompts.candidate_system()) ==
             "29e4a03ed3883b3d94c72fb49f3e76d108a390c755b8a883294f80ada905b1b6"

    assert Digest.sha256(Prompts.repair_system()) ==
             "2100d7c15a436222c826b9296553de921577ecb1203abfe6be3cbc7af9ebcbdc"

    assert Digest.sha256(Prompts.candidate_user("INSTRUCTIONS", "SOURCE")) ==
             "c1475c52004902dd4d53b1e9dc54fca8e7a063198692785fcbb06b25797af43c"
  end

  test "candidate call sends low reasoning effort with no tools and records usage", %{room: room} do
    parent = self()

    request = fn payload, _opts, endpoint ->
      send(parent, {:payload, payload, endpoint})

      {:ok,
       %{
         "id" => "resp_candidate_1",
         "output_text" =>
           Jason.encode!(%{
             "improved_skill_markdown" => Fixtures.improved_markdown(),
             "change_summary" => ["clarified the workflow"],
             "warnings" => []
           }),
         "usage" => %{
           "input_tokens" => 11,
           "output_tokens" => 22,
           "total_tokens" => 33,
           "input_tokens_details" => %{"cached_tokens" => 4}
         }
       }}
    end

    assert {:ok, generated} =
             CandidateGenerator.generate(room.source_markdown, %{"instructions" => "tighten"},
               request: request
             )

    assert generated.usage == %{"input_tokens" => 11, "output_tokens" => 22, "total_tokens" => 33}
    assert generated.model_response_id == "resp_candidate_1"

    assert_received {:payload, payload, "https://api.openai.com/v1/responses"}
    assert payload.model == "gpt-5.6-terra"
    assert payload.tools == []
    assert payload.reasoning == %{effort: "low"}
    assert payload.text.format.type == "json_schema"
    assert payload.text.format.strict == true

    assert [%{role: "system", content: [system]}, %{role: "user", content: [user]}] =
             payload.input

    assert system.text == Prompts.candidate_system()
    assert user.text == Prompts.candidate_user("tighten", room.source_markdown)
  end

  test "repair-plan call sends low reasoning effort and keeps only bounded token counters" do
    parent = self()

    request = fn payload, _opts, _endpoint ->
      send(parent, {:payload, payload})

      {:ok,
       %{
         "id" => "resp_repair_1",
         "output_text" => Jason.encode!(Fixtures.repair_plan()),
         "usage" => %{"input_tokens" => 5, "output_tokens" => 7}
       }}
    end

    assert {:ok, result} = Client.repair_plan(%{"goal" => "test"}, request: request)

    assert result.usage == %{"input_tokens" => 5, "output_tokens" => 7}
    assert Client.normalize_usage(%{"input_tokens" => -1, "output_tokens" => "many"}) == %{}
    assert Client.normalize_usage(nil) == %{}

    assert_received {:payload, payload}
    assert payload.reasoning == %{effort: "low"}
    assert payload.tools == []
    assert payload.text.format.strict == true
    assert [%{content: [system]} | _] = payload.input
    assert system.text == Prompts.repair_system()
  end

  test "candidate and repair-plan token usage both reach the proposal", %{
    room: room,
    revision: revision,
    browser_session: browser_session
  } do
    generator = fn _source, _arguments ->
      %{
        candidate_markdown: Fixtures.improved_markdown(),
        change_summary: ["clarified the workflow"],
        warnings: [],
        model: "usage-test",
        model_response_id: "resp_candidate_usage",
        prompt_version: "usage-v1",
        usage: %{"input_tokens" => 31, "output_tokens" => 12, "total_tokens" => 43}
      }
    end

    invocation =
      room
      |> InvocationRunner.invoke!(browser_session, revision, %{"instructions" => "usage"},
        request_uuid: Ash.UUID.generate(),
        generator: generator
      )
      |> verify_visible!(room.id)

    assert invocation.effective_status == :verified_failure

    assert invocation.handler_result["candidate_provenance"]["usage"] == %{
             "input_tokens" => 31,
             "output_tokens" => 12,
             "total_tokens" => 43
           }

    request = fn _payload, _opts, _endpoint ->
      {:ok,
       %{
         "id" => "resp_repair_usage",
         "output_text" => Jason.encode!(Fixtures.repair_plan()),
         "usage" => %{"input_tokens" => 5, "output_tokens" => 7, "total_tokens" => 12}
       }}
    end

    proposal = RepairPlanner.propose!(invocation, request: request)

    assert proposal.model_response_id == "resp_repair_usage"

    assert proposal.usage == %{
             "candidate" => %{
               "input_tokens" => 31,
               "output_tokens" => 12,
               "total_tokens" => 43
             },
             "repair_plan" => %{"input_tokens" => 5, "output_tokens" => 7, "total_tokens" => 12}
           }
  end

  test "candidate fallback is explicitly labeled and cache keys are exact", %{room: room} do
    instructions = %{"instructions" => "clarify the workflow"}

    assert {:ok, generated} =
             CandidateGenerator.generate(room.source_markdown, instructions,
               fallback: true,
               room: room
             )

    assert generated.fallback_used
    assert generated.model == "patchbay-demo-fallback"
    assert Enum.any?(generated.warnings, &String.contains?(&1, "fallback"))
    assert {:ok, ^generated} = CandidateCache.get(generated.generation_key)
    assert {:error, :generation_key_required} = CandidateCache.get(nil)
    assert {:error, :generation_key_required} = CandidateCache.put("", generated)
  end

  test "v1 reports success but effective verification fails until v2 changes visible state", %{
    room: room,
    revision: revision,
    browser_session: browser_session
  } do
    arguments = %{"instructions" => "clarify the workflow"}

    v1 = invoke_failed!(room, browser_session, revision, arguments)

    assert v1.handler_result["reported_success"]
    assert v1.handler_result["applied"] == false
    assert v1.effective_status == :verified_failure
    assert v1.failure_code == :CANDIDATE_EMPTY
    assert Patchbay.get_room_by_id!(room.id).candidate_markdown == nil

    plan = Fixtures.repair_plan()
    proposal = RepairPlanner.propose!(v1, plan: plan, fallback: true)
    assert proposal.status == :ready_for_approval
    assert proposal.canary_result["passed"]

    published =
      Elixir.Patchbay.Patchbay.RepairApprovalService.approve_and_publish!(proposal, "owner", %{})

    assert published.status == :published
    v2 = Patchbay.get_tool_revision!(proposal.candidate_tool_revision_id)
    assert %ToolRevision{status: :desired, generation: 2} = v2

    Patchbay.observe_browser_session!(browser_session, %{
      desired_generation: 2,
      observed_generation: 2,
      observed_tool_names: [v2.name],
      observed_contracts: %{v2.name => v2.contract_sha256},
      webmcp_supported: true
    })

    retried = InvocationRunner.retry!(v1, browser_session, fallback: true)

    assert_raise ArgumentError, ~r/room is not ready/, fn ->
      InvocationRunner.retry!(v1, browser_session, fallback: true)
    end

    retried = verify_visible!(retried, room.id)

    assert retried.handler_result["reported_success"]
    assert retried.handler_result["applied"]
    assert retried.effective_status == :verified_success
    assert Patchbay.get_room_by_id!(room.id).candidate_markdown == Fixtures.improved_markdown()
  end

  test "rejection retires the candidate and restores a recoverable failure", %{
    room: room,
    revision: revision,
    browser_session: browser_session
  } do
    invocation =
      invoke_failed!(room, browser_session, revision, %{"instructions" => "reject once"})

    proposal = RepairPlanner.propose!(invocation, plan: Fixtures.repair_plan(), fallback: true)
    candidate_id = proposal.candidate_tool_revision_id

    rejected = RepairApprovalService.reject!(proposal)
    recovered_room = Patchbay.get_room_by_id!(room.id)

    assert rejected.status == :rejected
    assert Patchbay.get_tool_revision!(candidate_id).status == :retired
    assert recovered_room.status == :failed
    assert recovered_room.active_repair_proposal_id == nil

    assert DemoReset.reset!(room).status == :ready
  end

  test "invocation request UUID replay is idempotent", %{
    room: room,
    revision: revision,
    browser_session: browser_session
  } do
    request_uuid = Ash.UUID.generate()

    first =
      InvocationRunner.invoke!(room, browser_session, revision, %{"instructions" => "tighten"},
        request_uuid: request_uuid,
        fallback: true
      )

    second =
      InvocationRunner.invoke!(room, browser_session, revision, %{"instructions" => "tighten"},
        request_uuid: request_uuid,
        fallback: true
      )

    assert second.id == first.id
    assert second.handler_result == first.handler_result
  end

  test "canary refuses a malformed candidate and timeline sequences are durable", %{
    room: room,
    revision: revision
  } do
    refute CanaryRunner.run(Fixtures.source_markdown(), "not markdown", revision).passed

    assert %{sequence: 1} = RoomTimeline.append!(room, :repair_requested, %{"test" => true})
    assert %{sequence: 2} = RoomTimeline.append!(room, :canary_failed, %{"test" => true})

    events =
      Patchbay.list_room_events!(query: [filter: [room_id: room.id], sort: [sequence: :asc]])

    assert Enum.map(events, & &1.sequence) == [1, 2]
  end

  test "approval recomputes the exact candidate canary and requires persisted failure evidence",
       %{
         room: room,
         revision: revision,
         browser_session: browser_session
       } do
    invocation = invoke_failed!(room, browser_session, revision, %{"instructions" => "tighten"})

    proposal = RepairPlanner.propose!(invocation, plan: Fixtures.repair_plan(), fallback: true)

    Repo.query!("UPDATE invocations SET effective_status = 'handler_returned' WHERE id = $1", [
      Ecto.UUID.dump!(invocation.id)
    ])

    assert_raise ArgumentError, ~r/verified failure/, fn ->
      RepairApprovalService.approve_and_publish!(proposal, "owner")
    end

    Repo.query!("UPDATE invocations SET effective_status = 'verified_failure' WHERE id = $1", [
      Ecto.UUID.dump!(invocation.id)
    ])

    Repo.query!(
      "UPDATE invocations SET generated_candidate_sha256 = $1 WHERE id = $2",
      [Digest.sha256("tampered"), Ecto.UUID.dump!(invocation.id)]
    )

    assert_raise ArgumentError, ~r/candidate digest/, fn ->
      RepairApprovalService.approve_and_publish!(proposal, "owner")
    end
  end

  test "same request UUID is atomically idempotent under concurrent delivery", %{
    room: room,
    revision: revision,
    browser_session: browser_session
  } do
    request_uuid = Ash.UUID.generate()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          InvocationRunner.invoke!(
            room,
            browser_session,
            revision,
            %{"instructions" => "concurrent"},
            request_uuid: request_uuid,
            fallback: true
          )
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 15_000))

    assert Enum.map(results, & &1.id) |> Enum.uniq() |> length() == 1

    events = RoomTimeline.list!(room.id)
    assert Enum.count(events, &(&1.kind == :invocation_started)) == 1
  end

  test "reset cancellation wins against a late generator result", %{
    room: room,
    revision: revision,
    browser_session: browser_session
  } do
    invocation =
      InvocationRunner.begin!(
        room,
        browser_session,
        revision,
        %{"instructions" => "finish after reset"}
      )

    parent = self()

    worker =
      spawn(fn ->
        result =
          try do
            {:ok,
             InvocationRunner.execute!(invocation,
               generator: fn _source, _arguments ->
                 send(parent, :generation_started)
                 receive do: (:release_generation -> :ok)

                 %{
                   candidate_markdown: Fixtures.improved_markdown(),
                   model: "race-test",
                   prompt_version: "race-v1",
                   change_summary: ["late result"],
                   warnings: []
                 }
               end
             )}
          rescue
            error -> {:error, error}
          end

        send(parent, {:execution_finished, result})
      end)

    assert_receive :generation_started, 1_000
    DemoReset.reset!(room)
    send(worker, :release_generation)

    assert_receive {:execution_finished, {:error, error}}, 1_000
    assert Exception.message(error) =~ "earlier room lifecycle"
    assert Patchbay.get_invocation!(invocation.id).effective_status == :cancelled

    reset_room = Patchbay.get_room_by_id!(room.id)
    assert reset_room.status == :ready
    assert reset_room.candidate_markdown == nil

    assert RoomTimeline.list!(room.id) |> List.last() |> Map.fetch!(:kind) == :room_reset
  end

  test "a stale begin cannot create work after reset", %{
    room: room,
    revision: revision,
    browser_session: browser_session
  } do
    DemoReset.reset!(room)

    assert_raise ArgumentError, ~r/earlier room lifecycle/, fn ->
      InvocationRunner.begin!(
        room,
        browser_session,
        revision,
        %{"instructions" => "stale begin"},
        invocation_epoch: room.invocation_epoch
      )
    end

    assert Patchbay.list_invocations!(query: [filter: [room_id: room.id]]) == []
  end

  test "cancelled work rejects late visible proof", %{
    room: room,
    revision: revision,
    browser_session: browser_session
  } do
    invocation =
      InvocationRunner.invoke!(
        room,
        browser_session,
        revision,
        %{"instructions" => "cancel before proof"},
        fallback: true
      )

    assert invocation.effective_status == :awaiting_visible_state
    assert InvocationRunner.cancel!(invocation).effective_status == :cancelled

    assert_raise ArgumentError, ~r/no longer awaiting visible proof/, fn ->
      InvocationRunner.verify!(invocation, %{})
    end

    assert Patchbay.list_verifications!(query: [filter: [invocation_id: invocation.id]]) == []
  end

  test "live candidate generation cannot reuse a fallback variant", %{room: room} do
    arguments = %{"instructions" => "separate providers"}

    assert {:ok, fallback} =
             CandidateGenerator.generate(room.source_markdown, arguments, fallback: true)

    live_candidate = String.replace(Fixtures.improved_markdown(), "Hello", "Hello live")

    assert {:ok, live} =
             CandidateGenerator.generate(room.source_markdown, arguments,
               generator: fn _source, _arguments ->
                 %{
                   candidate_markdown: live_candidate,
                   model: "live-test",
                   prompt_version: "live-v2",
                   change_summary: ["live"],
                   warnings: []
                 }
               end
             )

    refute live.fallback_used
    assert live.model == "live-test"
    assert live.candidate_markdown == live_candidate
    refute live.candidate_markdown == fallback.candidate_markdown
  end

  test "retry uses durable invocation candidate, not arbitrary cache contents", %{
    room: room,
    revision: revision,
    browser_session: browser_session
  } do
    invocation = invoke_failed!(room, browser_session, revision, %{"instructions" => "durable"})

    proposal = RepairPlanner.propose!(invocation, plan: Fixtures.repair_plan(), fallback: true)
    published = RepairApprovalService.approve_and_publish!(proposal, "owner")
    v2 = Patchbay.get_tool_revision!(published.candidate_tool_revision_id)

    Patchbay.observe_browser_session!(browser_session, %{
      desired_generation: 2,
      observed_generation: 2,
      observed_tool_names: [v2.name],
      observed_contracts: %{v2.name => v2.contract_sha256},
      webmcp_supported: true
    })

    CandidateCache.put(invocation.generation_key, %{
      candidate_markdown: "---\nname: bogus\n---\nwrong",
      candidate_sha256: Digest.sha256("---\nname: bogus\n---\nwrong"),
      generation_key: invocation.generation_key,
      input_sha256: Digest.sha256("bogus"),
      model: "attacker",
      model_response_id: "attacker",
      prompt_version: "attacker",
      fallback_used: false,
      fallback_reason: nil,
      change_summary: [],
      warnings: []
    })

    retried = InvocationRunner.retry!(invocation, browser_session)
    retried = verify_visible!(retried, room.id)

    assert retried.effective_status == :verified_success
    assert Patchbay.get_room_by_id!(room.id).candidate_markdown == Fixtures.improved_markdown()
  end

  test "planner inference failure leaves room and revisions unchanged", %{
    room: room,
    revision: revision,
    browser_session: browser_session
  } do
    invocation = invoke_failed!(room, browser_session, revision, %{"instructions" => "bad plan"})

    before_revisions = Patchbay.list_tool_revisions!(query: [filter: [room_id: room.id]])
    before_events = RoomTimeline.list!(room.id)

    assert_raise ArgumentError, ~r/repair plan rejected/, fn ->
      RepairPlanner.propose!(invocation,
        plan: Map.put(Fixtures.repair_plan(), "unknown", true),
        fallback: true
      )
    end

    after_room = Patchbay.get_room_by_id!(room.id)
    after_revisions = Patchbay.list_tool_revisions!(query: [filter: [room_id: room.id]])
    after_events = RoomTimeline.list!(room.id)

    assert after_room.status == :failed
    assert length(after_revisions) == length(before_revisions)
    assert Enum.map(after_events, & &1.id) == Enum.map(before_events, & &1.id)
  end

  test "canary failure is recorded as recoverable platform error", %{
    room: room,
    revision: revision,
    browser_session: browser_session
  } do
    invocation =
      invoke_failed!(room, browser_session, revision, %{"instructions" => "bad canary"})

    Repo.query!(
      "UPDATE invocations SET generated_candidate = $1, generated_candidate_sha256 = $2 WHERE id = $3",
      ["not markdown", Digest.sha256("not markdown"), Ecto.UUID.dump!(invocation.id)]
    )

    proposal = RepairPlanner.propose!(invocation, plan: Fixtures.repair_plan(), fallback: true)
    assert proposal.status == :canary_failed
    assert Patchbay.get_room_by_id!(room.id).status == :error

    assert Enum.any?(RoomTimeline.list!(room.id), &(&1.kind == :repair_requested))
    assert Enum.any?(RoomTimeline.list!(room.id), &(&1.kind == :canary_failed))
    assert Enum.any?(RoomTimeline.list!(room.id), &(&1.kind == :platform_error))
  end

  test "stale browser session cannot apply a v2 retry", %{
    room: room,
    revision: revision,
    browser_session: browser_session
  } do
    invocation = invoke_failed!(room, browser_session, revision, %{"instructions" => "stale"})

    proposal = RepairPlanner.propose!(invocation, plan: Fixtures.repair_plan(), fallback: true)
    published = RepairApprovalService.approve_and_publish!(proposal, "owner")
    v2 = Patchbay.get_tool_revision!(published.candidate_tool_revision_id)

    Patchbay.observe_browser_session!(browser_session, %{
      desired_generation: 1,
      observed_generation: 1,
      observed_tool_names: [revision.name],
      observed_contracts: %{revision.name => revision.contract_sha256},
      webmcp_supported: false
    })

    before = Patchbay.get_room_by_id!(room.id)

    assert_raise ArgumentError, ~r/browser session/, fn ->
      InvocationRunner.retry!(invocation, browser_session)
    end

    after_room = Patchbay.get_room_by_id!(room.id)
    assert after_room.candidate_markdown == before.candidate_markdown
    assert after_room.ui_revision == before.ui_revision
    assert v2.status == :desired
  end

  defp invoke_failed!(room, browser_session, revision, arguments) do
    room
    |> InvocationRunner.invoke!(browser_session, revision, arguments,
      request_uuid: Ash.UUID.generate(),
      fallback: true
    )
    |> verify_visible!(room.id)
  end

  defp verify_visible!(invocation, room_id) do
    room = Patchbay.get_room_by_id!(room_id)

    InvocationRunner.verify!(invocation, %{
      "ui_revision" => room.ui_revision,
      "source" => %{"present" => true, "sha256" => room.source_sha256},
      "candidate" => %{
        "present" => is_binary(room.candidate_markdown),
        "sha256" => room.candidate_sha256
      }
    })
  end

  # Every room is created already offering its generation-1 tool.
  defp seeded_revision!(room) do
    Patchbay.list_tool_revisions!(query: [filter: [room_id: room.id, status: :desired], limit: 1])
    |> List.first()
  end
end
