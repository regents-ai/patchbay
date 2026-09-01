defmodule Patchbay.Patchbay.TelemetryLoggerTest do
  use Patchbay.DataCase, async: false

  import ExUnit.CaptureLog

  alias Elixir.Patchbay.Patchbay

  alias Elixir.Patchbay.Patchbay.{
    Digest,
    InvocationRunner,
    RoomTimeline,
    Telemetry,
    TelemetryLogger
  }

  @room "11111111-1111-1111-1111-111111111111"
  @session "22222222-2222-2222-2222-222222222222"
  @invocation "33333333-3333-3333-3333-333333333333"
  @revision "44444444-4444-4444-4444-444444444444"
  @contract String.duplicate("a", 64)
  @args String.duplicate("b", 64)
  @tool "uplift_current_skill_v1"

  setup do
    # The application attaches the handler at boot; these tests only need the
    # :info lines to survive the test logger level.
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    :ok
  end

  describe "line format" do
    test "webmcp.registered" do
      assert lines(fn -> Telemetry.webmcp_registered(webmcp_metadata()) end) ==
               [
                 "[webmcp] webmcp.registered room=#{@room} session=#{@session} generation=1 contract=#{@contract}"
               ]
    end

    test "webmcp.unregistered" do
      assert lines(fn -> Telemetry.webmcp_unregistered(webmcp_metadata()) end) ==
               [
                 "[webmcp] webmcp.unregistered room=#{@room} session=#{@session} generation=1 contract=#{@contract}"
               ]
    end

    test "webmcp.toolchange" do
      assert lines(fn -> Telemetry.webmcp_toolchange(webmcp_metadata()) end) ==
               [
                 "[webmcp] webmcp.toolchange room=#{@room} session=#{@session} generation=1 contract=#{@contract}"
               ]
    end

    test "invocation.start" do
      metadata = %{
        room_id: @room,
        browser_session_id: @session,
        invocation_id: @invocation,
        tool_generation: 1,
        tool_name: @tool,
        contract_sha256: @contract,
        arguments_sha256: @args
      }

      assert lines(fn -> Telemetry.invocation_start(metadata) end) ==
               [
                 "[webmcp] invocation.start room=#{@room} session=#{@session} invocation=#{@invocation} generation=1 tool=#{@tool} contract=#{@contract} args=#{@args}"
               ]
    end

    test "invocation.handler_stop reports a raw handler success" do
      assert lines(fn ->
               Telemetry.invocation_handler_stop(
                 %{duration: native(42), input_tokens: 31, output_tokens: 12},
                 %{
                   room_id: @room,
                   browser_session_id: @session,
                   invocation_id: @invocation,
                   tool_generation: 1,
                   tool_name: @tool,
                   contract_sha256: @contract,
                   arguments_sha256: @args,
                   fallback_used: false,
                   failure_code: nil
                 }
               )
             end) ==
               [
                 "[webmcp] invocation.handler_stop room=#{@room} session=#{@session} invocation=#{@invocation} generation=1 tool=#{@tool} contract=#{@contract} args=#{@args} outcome=success failure_code=- duration_ms=42 fallback_used=false"
               ]
    end

    test "invocation.handler_stop reports a handler failure and the demo fallback" do
      assert lines(fn ->
               Telemetry.invocation_handler_stop(
                 %{duration: native(8)},
                 %{
                   room_id: @room,
                   browser_session_id: @session,
                   invocation_id: @invocation,
                   tool_generation: 2,
                   fallback_used: true,
                   failure_code: :MODEL_GENERATION_FAILED
                 }
               )
             end) ==
               [
                 "[webmcp] invocation.handler_stop room=#{@room} session=#{@session} invocation=#{@invocation} generation=2 tool=- contract=- args=- outcome=failure failure_code=MODEL_GENERATION_FAILED duration_ms=8 fallback_used=true"
               ]
    end

    test "verification.stop" do
      assert lines(fn ->
               Telemetry.verification_stop(
                 %{duration: native(7), ui_commit_ms: 5},
                 %{
                   room_id: @room,
                   invocation_id: @invocation,
                   passed: false,
                   failure_code: :CANDIDATE_EMPTY
                 }
               )
             end) ==
               [
                 "[webmcp] verification.stop room=#{@room} invocation=#{@invocation} outcome=failure failure_code=CANDIDATE_EMPTY duration_ms=7"
               ]
    end

    test "repair.model_stop" do
      assert lines(fn ->
               Telemetry.repair_model_stop(
                 %{duration: native(120), input_tokens: 90},
                 %{room_id: @room, invocation_id: @invocation, fallback_used: true}
               )
             end) ==
               [
                 "[webmcp] repair.model_stop room=#{@room} invocation=#{@invocation} duration_ms=120 fallback_used=true"
               ]
    end

    test "repair.canary_stop" do
      assert lines(fn ->
               Telemetry.repair_canary_stop(
                 %{duration: native(3)},
                 %{
                   room_id: @room,
                   invocation_id: @invocation,
                   tool_revision_id: @revision,
                   passed: true,
                   failure_code: nil
                 }
               )
             end) ==
               [
                 "[webmcp] repair.canary_stop room=#{@room} invocation=#{@invocation} revision=#{@revision} outcome=success failure_code=- duration_ms=3"
               ]
    end

    test "publication.stop" do
      assert lines(fn ->
               Telemetry.publication_stop(
                 %{duration: native(9)},
                 %{room_id: @room, tool_revision_id: @revision, tool_generation: 2}
               )
             end) ==
               [
                 "[webmcp] publication.stop room=#{@room} revision=#{@revision} generation=2 duration_ms=9"
               ]
    end

    test "goal.verified" do
      assert lines(fn ->
               Telemetry.goal_verified(%{
                 room_id: @room,
                 invocation_id: @invocation,
                 tool_generation: 2
               })
             end) ==
               ["[webmcp] goal.verified room=#{@room} invocation=#{@invocation} generation=2"]
    end
  end

  describe "shape" do
    test "every emitted event has a logged column order" do
      for event <- Telemetry.events() do
        assert is_list(TelemetryLogger.columns(event)),
               "#{inspect(event)} has no logged columns"
      end
    end

    test "a value the event does not carry prints as a dash" do
      assert lines(fn -> Telemetry.goal_verified(%{}) end) ==
               ["[webmcp] goal.verified room=- invocation=- generation=-"]
    end

    test "a value the sanitizer rejected prints as unavailable" do
      assert lines(fn ->
               Telemetry.publication_stop(
                 %{duration: "not a number"},
                 %{
                   room_id: String.duplicate("a", 200),
                   tool_revision_id: %{"secret" => "value"},
                   tool_generation: 2
                 }
               )
             end) ==
               [
                 "[webmcp] publication.stop room=unavailable revision=unavailable generation=2 duration_ms=-"
               ]
    end

    test "attaching again is a no-op" do
      assert TelemetryLogger.attach() == :ok
      assert TelemetryLogger.attach() == :ok

      assert lines(fn -> Telemetry.goal_verified(%{room_id: @room}) end) ==
               ["[webmcp] goal.verified room=#{@room} invocation=- generation=-"]
    end
  end

  describe "content" do
    test "arguments and free text never reach the log" do
      secret = "sk-live-DO-NOT-LOG-8f3a2b"

      log =
        capture_log(fn ->
          Telemetry.invocation_handler_stop(
            %{duration: native(11)},
            %{
              room_id: @room,
              browser_session_id: @session,
              invocation_id: @invocation,
              tool_generation: 1,
              fallback_used: false,
              failure_code: nil,
              arguments: %{"instructions" => secret},
              candidate_markdown: "---\ntitle: #{secret}\n---",
              source: secret
            }
          )
        end)

      refute log =~ secret
      refute log =~ "instructions"
      refute log =~ "candidate_markdown"

      assert webmcp_lines(log) == [
               "[webmcp] invocation.handler_stop room=#{@room} session=#{@session} invocation=#{@invocation} generation=1 tool=- contract=- args=- outcome=success failure_code=- duration_ms=11 fallback_used=false"
             ]
    end
  end

  describe "the live loop" do
    test "a real invocation writes registration, handler, and verification lines" do
      room = Patchbay.create_seeded_room!("room-#{System.unique_integer([:positive])}")
      revision = seeded_revision!(room)

      browser_session =
        Patchbay.register_browser_session!(%{
          room_id: room.id,
          client_instance_id: Ash.UUID.generate(),
          user_agent_digest: Digest.sha256("test-agent"),
          webmcp_supported: true
        })

      log =
        capture_log(fn ->
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

          room
          |> InvocationRunner.invoke!(browser_session, revision, %{"instructions" => "log"},
            request_uuid: Ash.UUID.generate(),
            fallback: true
          )
          |> verify_visible!(room.id)
        end)

      logged = webmcp_lines(log)

      assert "[webmcp] webmcp.registered room=#{room.id} session=#{browser_session.id} generation=#{revision.generation} contract=#{revision.contract_sha256}" in logged

      assert Enum.any?(
               logged,
               &(&1 =~
                   ~r/^\[webmcp\] invocation\.start room=#{room.id} session=#{browser_session.id} invocation=[0-9a-f-]{36} generation=1 tool=#{revision.name} contract=#{revision.contract_sha256} args=[0-9a-f]{64}$/)
             )

      assert Enum.any?(
               logged,
               &(&1 =~
                   ~r/^\[webmcp\] invocation\.handler_stop room=#{room.id} session=#{browser_session.id} invocation=[0-9a-f-]{36} generation=1 tool=#{revision.name} contract=#{revision.contract_sha256} args=[0-9a-f]{64} outcome=success failure_code=- duration_ms=\d+ fallback_used=true$/)
             )

      assert Enum.any?(
               logged,
               &(&1 =~
                   ~r/^\[webmcp\] verification\.stop room=#{room.id} invocation=[0-9a-f-]{36} outcome=failure failure_code=CANDIDATE_EMPTY duration_ms=\d+$/)
             )
    end
  end

  defp webmcp_metadata do
    %{
      room_id: @room,
      browser_session_id: @session,
      tool_generation: 1,
      contract_sha256: @contract
    }
  end

  defp lines(fun), do: fun |> capture_log() |> webmcp_lines()

  defp webmcp_lines(log) do
    log
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> then(&Regex.scan(~r/\[webmcp\][^\n]*/, &1))
    |> Enum.map(&hd/1)
  end

  defp native(milliseconds),
    do: System.convert_time_unit(milliseconds, :millisecond, :native)

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

  defp seeded_revision!(room) do
    Patchbay.list_tool_revisions!(query: [filter: [room_id: room.id, status: :desired], limit: 1])
    |> List.first()
  end
end
