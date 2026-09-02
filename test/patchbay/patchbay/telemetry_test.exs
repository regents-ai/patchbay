defmodule Patchbay.Patchbay.TelemetryTest do
  use Patchbay.DataCase, async: false

  alias Elixir.Patchbay.Forum
  alias Elixir.Patchbay.Forum.PatchbayAgent
  alias Elixir.Patchbay.Forum.RoomMirror
  alias Elixir.Patchbay.Patchbay

  alias Elixir.Patchbay.Patchbay.{
    CandidateCache,
    Digest,
    Fixtures,
    InvocationRunner,
    RepairApprovalService,
    RepairPlanner,
    RoomTimeline,
    Telemetry
  }

  @documented_metadata %{
    [:patchbay, :webmcp, :registered] => [
      :room_id,
      :browser_session_id,
      :tool_generation,
      :contract_sha256
    ],
    [:patchbay, :webmcp, :unregistered] => [
      :room_id,
      :browser_session_id,
      :tool_generation,
      :contract_sha256
    ],
    [:patchbay, :webmcp, :toolchange] => [
      :room_id,
      :browser_session_id,
      :tool_generation,
      :contract_sha256
    ],
    [:patchbay, :invocation, :start] => [
      :room_id,
      :browser_session_id,
      :invocation_id,
      :tool_generation,
      :tool_name,
      :contract_sha256,
      :arguments_sha256
    ],
    [:patchbay, :invocation, :handler_stop] => [
      :room_id,
      :browser_session_id,
      :invocation_id,
      :tool_generation,
      :tool_name,
      :contract_sha256,
      :arguments_sha256,
      :fallback_used,
      :failure_code,
      :receipt
    ],
    [:patchbay, :verification, :stop] => [:room_id, :invocation_id, :passed, :failure_code],
    [:patchbay, :repair, :model_stop] => [:room_id, :invocation_id, :fallback_used],
    [:patchbay, :repair, :canary_stop] => [
      :room_id,
      :invocation_id,
      :tool_revision_id,
      :passed,
      :failure_code
    ],
    [:patchbay, :publication, :stop] => [:room_id, :tool_revision_id, :tool_generation],
    [:patchbay, :goal, :verified] => [:room_id, :invocation_id, :tool_generation],
    [:patchbay, :agent, :repair_start] => [:room_id, :report_id, :attempt_id],
    [:patchbay, :agent, :repair_stop] => [
      :room_id,
      :report_id,
      :attempt_id,
      :outcome,
      :contract_sha256
    ]
  }

  # The loop a person drives never reaches the worker that answers a report, so
  # the two flows below cover the event list between them.
  @agent_events [[:patchbay, :agent, :repair_start], [:patchbay, :agent, :repair_stop]]

  @required_measurements %{
    [:patchbay, :invocation, :start] => [:system_time],
    [:patchbay, :invocation, :handler_stop] => [:duration],
    [:patchbay, :verification, :stop] => [:duration],
    [:patchbay, :repair, :model_stop] => [:duration],
    [:patchbay, :repair, :canary_stop] => [:duration],
    [:patchbay, :publication, :stop] => [:duration],
    [:patchbay, :agent, :repair_start] => [:system_time],
    [:patchbay, :agent, :repair_stop] => [:duration]
  }

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

    parent = self()
    handler_id = "patchbay-telemetry-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      Telemetry.events(),
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{room: room, revision: revision, browser_session: browser_session}
  end

  test "the deterministic loop emits every spec event with its documented keys", %{
    room: room,
    revision: revision,
    browser_session: browser_session
  } do
    RoomTimeline.append!(
      room,
      :tool_registered,
      %{
        "tool_name" => revision.name,
        "generation" => revision.generation,
        "contract_sha256" => revision.contract_sha256
      },
      browser_session_id: browser_session.id
    )

    RoomTimeline.append!(
      room,
      :toolchange_observed,
      %{"generation" => revision.generation},
      browser_session_id: browser_session.id
    )

    RoomTimeline.append!(
      room,
      :tool_unregistered,
      %{
        "tool_name" => revision.name,
        "generation" => revision.generation,
        "contract_sha256" => revision.contract_sha256
      },
      browser_session_id: browser_session.id
    )

    failed =
      room
      |> InvocationRunner.invoke!(browser_session, revision, %{"instructions" => "telemetry"},
        request_uuid: Ash.UUID.generate(),
        fallback: true
      )
      |> verify_visible!(room.id)

    assert failed.effective_status == :verified_failure

    proposal = RepairPlanner.propose!(failed, plan: Fixtures.repair_plan(), fallback: true)
    published = RepairApprovalService.approve_and_publish!(proposal, "owner")
    v2 = Patchbay.get_tool_revision!(published.candidate_tool_revision_id)

    Patchbay.observe_browser_session!(browser_session, %{
      desired_generation: 2,
      observed_generation: 2,
      observed_tool_names: [v2.name],
      observed_contracts: %{v2.name => v2.contract_sha256},
      webmcp_supported: true
    })

    verified =
      failed
      |> InvocationRunner.retry!(browser_session)
      |> verify_visible!(room.id)

    assert verified.effective_status == :verified_success

    events = drain_telemetry()

    for event <- Telemetry.events() -- @agent_events do
      assert Map.has_key?(events, event), "expected #{inspect(event)} to be emitted"
    end

    assert_documented!(events)
  end

  test "the worker that answers a report emits its own two events" do
    Application.put_env(:patchbay, :demo_fallback, true)
    on_exit(fn -> Application.delete_env(:patchbay, :demo_fallback) end)

    call = failed_call()

    Forum.file_report!(%{
      tool_id: board_tool_id(call),
      browser_session_id: call.forum_session_id,
      arguments_sha256: call.invocation.arguments_sha256,
      handler_result: %{"reported_success" => true},
      observed: %{"candidate_present" => false},
      verdict: :verified_failure,
      failure_code: "CANDIDATE_EMPTY",
      note: "It said it worked, but the page did nothing.",
      receipt: call.invocation.receipt
    })

    assert {:ok, attempt} = PatchbayAgent.sweep()
    assert attempt.status == :published

    events = drain_telemetry()

    for event <- @agent_events do
      assert Map.has_key?(events, event), "expected #{inspect(event)} to be emitted"
    end

    assert [{_measurements, stop}] = Map.fetch!(events, [:patchbay, :agent, :repair_stop])
    assert stop.outcome == :published
    assert stop.contract_sha256 =~ ~r/\A[0-9a-f]{64}\z/

    assert_documented!(events)
  end

  test "the handler stop carries the model token usage and the invocation stores it", %{
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
        model_response_id: "resp_usage_test",
        prompt_version: "usage-v1",
        usage: %{"input_tokens" => 31, "output_tokens" => 12, "total_tokens" => 43}
      }
    end

    invocation =
      InvocationRunner.invoke!(room, browser_session, revision, %{"instructions" => "usage"},
        request_uuid: Ash.UUID.generate(),
        generator: generator
      )

    assert invocation.handler_result["candidate_provenance"]["usage"] == %{
             "input_tokens" => 31,
             "output_tokens" => 12,
             "total_tokens" => 43
           }

    assert_receive {:telemetry, [:patchbay, :invocation, :handler_stop], measurements, metadata}

    assert measurements.input_tokens == 31
    assert measurements.output_tokens == 12
    assert metadata.fallback_used == false
    assert metadata.invocation_id == invocation.id
  end

  test "oversized or unshaped values never reach a handler" do
    Telemetry.publication_stop(
      %{duration: "not a number"},
      %{
        room_id: String.duplicate("a", 200),
        tool_revision_id: %{"secret" => "value"},
        tool_generation: 2
      }
    )

    assert_receive {:telemetry, [:patchbay, :publication, :stop], measurements, metadata}

    assert measurements == %{}
    assert metadata.room_id == :unavailable
    assert metadata.tool_revision_id == :unavailable
    assert metadata.tool_generation == 2
  end

  defp assert_documented!(events) do
    Enum.each(events, fn {event, emissions} ->
      Enum.each(emissions, fn {measurements, metadata} ->
        assert Map.keys(metadata) |> Enum.sort() ==
                 Enum.sort(Map.fetch!(@documented_metadata, event)),
               "#{inspect(event)} metadata keys drifted: #{inspect(Map.keys(metadata))}"

        for key <- Map.get(@required_measurements, event, []) do
          assert is_number(Map.get(measurements, key)),
                 "#{inspect(event)} is missing the #{key} measurement"
        end

        assert_no_content(event, measurements)
        assert_no_content(event, metadata)
      end)
    end)
  end

  # One real failed call on a studio of this deployment, from a browser holding
  # a forum identity, which is what a receipt-verified report needs behind it.
  defp failed_call do
    room = Patchbay.create_seeded_room!("room-#{System.unique_integer([:positive])}")
    revision = seeded_revision!(room)
    forum_session_id = Ash.UUID.generate()

    browser_session =
      Patchbay.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: Ash.UUID.generate(),
        forum_session_id: forum_session_id,
        user_agent_digest: Digest.sha256("test-agent"),
        webmcp_supported: true
      })

    invocation =
      room
      |> InvocationRunner.invoke!(browser_session, revision, %{"instructions" => "warmer"},
        request_uuid: Ash.UUID.generate(),
        fallback: true
      )
      |> verify_visible!(room.id)

    %{room: room, revision: revision, forum_session_id: forum_session_id, invocation: invocation}
  end

  defp board_tool_id(call) do
    site = Forum.register_site!(RoomMirror.origin())

    Forum.observe_tool!(%{
      site_id: site.id,
      name: call.revision.name,
      contract_sha256: call.revision.contract_sha256,
      title: call.revision.title,
      description: call.revision.description
    }).id
  end

  defp assert_no_content(event, values) do
    Enum.each(values, fn {key, value} ->
      if is_binary(value) do
        assert byte_size(value) <= 200,
               "#{inspect(event)} #{key} carries #{byte_size(value)} bytes of content"

        refute String.contains?(value, "---"),
               "#{inspect(event)} #{key} carries frontmatter"
      end
    end)
  end

  defp drain_telemetry(acc \\ %{}) do
    receive do
      {:telemetry, event, measurements, metadata} ->
        drain_telemetry(
          Map.update(acc, event, [{measurements, metadata}], &[{measurements, metadata} | &1])
        )
    after
      0 -> acc
    end
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
