defmodule PatchbayWeb.WebMCP.RoomLiveTest do
  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.{Digest, Fixtures}

  setup %{conn: conn} do
    room = Domain.create_seeded_room!()

    Fixtures.revision_attributes(room.id)
    |> Map.delete(:contract_sha256)
    |> Domain.create_tool_revision!()

    previous_fallback = Application.get_env(:patchbay, :demo_fallback)
    Application.put_env(:patchbay, :demo_fallback, true)

    on_exit(fn ->
      if is_nil(previous_fallback) do
        Application.delete_env(:patchbay, :demo_fallback)
      else
        Application.put_env(:patchbay, :demo_fallback, previous_fallback)
      end
    end)

    %{conn: conn, room: room}
  end

  test "renders the seeded room with stable editor and state identifiers", %{conn: conn} do
    {:ok, view, html} = live(conn, "/webmcp/rooms/skill-uplift")

    assert html =~ "Skill Uplift Studio"
    assert has_element?(view, "#patchbay-source-editor")
    assert has_element?(view, "#patchbay-candidate-editor")
    assert has_element?(view, "#patchbay-room-state[data-ui-revision=\"0\"]")
    assert has_element?(view, "[id^=patchbay-webmcp-]")
    assert html =~ "Candidate editor"
    assert html =~ "empty"
  end

  test "updates source digest through the same room page", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, "/webmcp/rooms/skill-uplift")
    source = room.source_markdown <> "\n\n## Local note\n"

    html = render_submit(view |> form("#patchbay-source-form"), %{"source_markdown" => source})

    assert html =~ Digest.sha256(source)
    assert Domain.get_room_by_id!(room.id).source_sha256 == Digest.sha256(source)
  end

  test "locks the source once invocation evidence exists", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, "/webmcp/rooms/skill-uplift")
    session = bootstrap(view, room)
    invoke_v1(view, room, session)
    original_source = Domain.get_room_by_id!(room.id).source_markdown

    html =
      render_submit(view |> form("#patchbay-source-form"), %{
        "source_markdown" => original_source <> "\nchanged"
      })

    assert html =~ "Platform error"
    assert Domain.get_room_by_id!(room.id).source_markdown == original_source
  end

  test "shows raw success beside effective visible failure and fallback provenance", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, "/webmcp/rooms/skill-uplift")
    session = bootstrap(view, room)
    revision = desired_revision(room)

    _accepted_html =
      render_hook(view, "webmcp_invocation_begin", %{
        "room_id" => room.id,
        "browser_session_id" => session.id,
        "invocation_epoch" => invocation_epoch(view),
        "request_uuid" => Ash.UUID.generate(),
        "tool_name" => revision.name,
        "contract_sha256" => revision.contract_sha256,
        "arguments" => %{"instructions" => "clarify the workflow"}
      })

    invocation = latest_invocation(room)

    render_hook(view, "webmcp_execute", %{
      "invocation_id" => invocation.id,
      "invocation_epoch" => invocation_epoch(view)
    })

    awaiting_html = render_async(view)
    assert awaiting_html =~ "Awaiting Visible State"
    html = observe_latest_poststate(view, room, session)

    assert html =~ "Raw handler result"
    assert html =~ "success"
    assert html =~ "Visible postcondition failed"
    assert html =~ "CANDIDATE_EMPTY"
    assert html =~ "Demo fallback used"
    assert Domain.get_room_by_id!(room.id).status == :failed
    assert Domain.get_room_by_id!(room.id).candidate_markdown == nil
  end

  test "runs repair, human approval, observed generation, retry, and reset on one page", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, "/webmcp/rooms/skill-uplift")

    html = render_click(view, "reset_demo")
    assert html =~ "Generation 1"
    assert html =~ "Candidate editor"
    assert html =~ "empty"
    refute html =~ ">Published<"
    assert Domain.get_room_by_id!(room.id).candidate_markdown == nil
    assert Domain.get_room_by_id!(room.id).status == :ready

    session = bootstrap(view, room)
    invoke_v1(view, room, session)

    render_click(view, "request_repair")
    html = render_async(view)

    assert html =~ "CONTRACT DIFF"
    assert html =~ "DETERMINISTIC CANARY"
    assert html =~ "Approve &amp; hot-swap"

    proposal =
      Domain.list_repair_proposals!(
        query: [filter: [room_id: room.id], sort: [inserted_at: :desc], limit: 1]
      )
      |> List.first()

    assert proposal.status == :ready_for_approval

    html = render_click(view, "approve_repair", %{"approved_by" => "forged-browser-value"})
    assert html =~ "Generation 2"
    assert html =~ "Publication requested"

    v1 =
      Domain.list_tool_revisions!(query: [filter: [room_id: room.id, generation: 1], limit: 1])
      |> List.first()

    assert has_element?(view, "#patchbay-invocation-evidence code", v1.name)

    assert Domain.get_repair_proposal!(proposal.id).approved_by == "owner"

    v2 = Domain.get_tool_revision!(proposal.candidate_tool_revision_id)
    proposal_id = proposal.id

    publication_event = "patchbay:#{room.id}:publication_requested"

    assert_push_event(view, ^publication_event, %{"proposal_id" => ^proposal_id})

    html =
      render_hook(view, "webmcp_toolchange_observed", %{
        "room_id" => room.id,
        "browser_session_id" => session.id,
        "observed_generation" => 2,
        "observed_tool_names" => [v2.name],
        "observed_contracts" => %{v2.name => v2.contract_sha256}
      })

    assert html =~ "toolchange observed"
    assert html =~ "Observed G2"

    awaiting_html = render_click(view, "retry_original_goal")
    assert awaiting_html =~ "Awaiting Visible State"

    retry_event = "patchbay:#{room.id}:ui_retry_started"
    assert_push_event(view, ^retry_event, %{"invocation_id" => _invocation_id})

    html = observe_latest_poststate(view, room, session)

    assert html =~ "Verification passed"
    assert html =~ Digest.sha256(Fixtures.improved_markdown())
    assert html =~ "ready"

    assert has_element?(
             view,
             "#patchbay-room-state[data-verification-passed=\"true\"][data-repair-approved=\"true\"]"
           )

    assert Domain.get_room_by_id!(room.id).status == :verified

    html = render_click(view, "reset_demo")
    assert html =~ "Generation 1"
    assert html =~ "Candidate editor"
    assert html =~ "empty"
    refute html =~ ">Published<"
    assert Domain.get_room_by_id!(room.id).candidate_markdown == nil
    assert Domain.get_room_by_id!(room.id).status == :ready
    reset_event = "patchbay:#{room.id}:reset_browser_registry"
    room_id = room.id
    assert_push_event(view, ^reset_event, %{"room_id" => ^room_id})
  end

  test "reset invalidates a stale repair callback", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, "/webmcp/rooms/skill-uplift")
    session = bootstrap(view, room)
    invoke_v1(view, room, session)

    render_click(view, "request_repair")

    {:ok, pending_socket} = Phoenix.LiveView.Debug.socket(view.pid)
    repair_token = pending_socket.assigns.repair_token
    assert is_binary(repair_token)

    html = render_click(view, "reset_demo")

    assert html =~ "Generation 1"
    {:ok, reset_socket} = Phoenix.LiveView.Debug.socket(view.pid)
    assert reset_socket.assigns.pending_operation == nil
    assert reset_socket.assigns.repair_token == nil

    assert {:noreply, callback_socket} =
             PatchbayWeb.WebMCP.RoomLive.Show.handle_async(
               {:repair, repair_token},
               {:ok, {:repair_result, repair_token, {:ok, :stale}}},
               reset_socket
             )

    assert callback_socket.assigns.room.status == :ready
    assert callback_socket.assigns.pending_operation == nil
    assert callback_socket.assigns.repair_token == nil
  end

  test "reset fences a stale invocation completion", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/webmcp/rooms/skill-uplift")
    request_uuid = Ash.UUID.generate()

    render_click(view, "reset_demo")
    {:ok, reset_socket} = Phoenix.LiveView.Debug.socket(view.pid)

    assert reset_socket.assigns.invocation_epoch == 1
    assert reset_socket.assigns.invocation_keys == MapSet.new()

    assert {:noreply, callback_socket} =
             PatchbayWeb.WebMCP.RoomLive.Show.handle_async(
               {:invocation, 0, request_uuid},
               {:ok, {:error, :late_result}},
               reset_socket
             )

    assert callback_socket.assigns.invocation_epoch == 1
    assert callback_socket.assigns.error_message == nil
  end

  test "reset broadcasts its epoch and cancels work begun in another tab", %{
    conn: conn,
    room: room
  } do
    {:ok, reset_view, _html} = live(conn, "/webmcp/rooms/skill-uplift")
    {:ok, stale_view, _html} = live(conn, "/webmcp/rooms/skill-uplift")
    session = bootstrap(stale_view, room)
    revision = desired_revision(room)
    request_uuid = Ash.UUID.generate()

    render_hook(stale_view, "webmcp_invocation_begin", %{
      "room_id" => room.id,
      "browser_session_id" => session.id,
      "invocation_epoch" => 0,
      "request_uuid" => request_uuid,
      "tool_name" => revision.name,
      "contract_sha256" => revision.contract_sha256,
      "arguments" => %{"instructions" => "wait across reset"}
    })

    invocation = latest_invocation(room)
    assert invocation.effective_status == :started

    render_click(reset_view, "reset_demo")
    reset_event = "patchbay:#{room.id}:reset_browser_registry"
    assert_push_event(stale_view, ^reset_event, %{"invocation_epoch" => 1})

    html =
      render_hook(stale_view, "webmcp_execute", %{
        "invocation_id" => invocation.id,
        "invocation_epoch" => 0
      })

    assert html =~ "invocation belongs to an earlier room lifecycle"
    assert invocation_epoch(stale_view) == 1
    assert Domain.get_invocation!(invocation.id).effective_status == :cancelled
  end

  test "begin failures return an error without terminating the room", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, "/webmcp/rooms/skill-uplift")
    session = bootstrap(view, room)
    revision = desired_revision(room)
    request_uuid = Ash.UUID.generate()

    params = %{
      "room_id" => room.id,
      "browser_session_id" => session.id,
      "invocation_epoch" => invocation_epoch(view),
      "request_uuid" => request_uuid,
      "tool_name" => revision.name,
      "contract_sha256" => revision.contract_sha256,
      "arguments" => %{"instructions" => "first request"}
    }

    render_hook(view, "webmcp_invocation_begin", params)

    html =
      render_hook(view, "webmcp_invocation_begin", %{
        params
        | "arguments" => %{"instructions" => "conflicting replay"}
      })

    assert html =~ "request UUID is already bound to different invocation evidence"
    assert render(view) =~ "Skill Uplift Studio"
  end

  test "the browser can durably cancel a begun invocation", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, "/webmcp/rooms/skill-uplift")
    session = bootstrap(view, room)
    revision = desired_revision(room)

    render_hook(view, "webmcp_invocation_begin", %{
      "room_id" => room.id,
      "browser_session_id" => session.id,
      "invocation_epoch" => invocation_epoch(view),
      "request_uuid" => Ash.UUID.generate(),
      "tool_name" => revision.name,
      "contract_sha256" => revision.contract_sha256,
      "arguments" => %{"instructions" => "cancel me"}
    })

    invocation = latest_invocation(room)

    render_hook(view, "webmcp_invocation_cancel", %{
      "room_id" => room.id,
      "browser_session_id" => session.id,
      "invocation_epoch" => invocation_epoch(view),
      "invocation_id" => invocation.id
    })

    assert Domain.get_invocation!(invocation.id).effective_status == :cancelled
  end

  test "discloses a browser registry error instead of accepting a forged room event", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, "/webmcp/rooms/skill-uplift")

    html =
      render_hook(view, "webmcp_registry_reconciled", %{
        "room_id" => Ash.UUID.generate(),
        "observed_generation" => 1,
        "observed_tool_names" => [],
        "observed_contracts" => %{}
      })

    assert html =~ "event belongs to another room"
    assert Domain.list_room_events!(query: [filter: [room_id: room.id], limit: 1]) == []
  end

  test "rejects registry claims outside the current server-owned toolset", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, "/webmcp/rooms/skill-uplift")
    session = bootstrap(view, room)

    html =
      render_hook(view, "webmcp_registry_reconciled", %{
        "room_id" => room.id,
        "browser_session_id" => session.id,
        "observed_generation" => 1,
        "observed_tool_names" => ["foreign_tool"],
        "observed_contracts" => %{"foreign_tool" => String.duplicate("f", 64)}
      })

    assert html =~ "observed registry contains a tool Patchbay does not own"
    observed = Domain.get_browser_session!(session.id)
    assert observed.observed_tool_names == []
    assert observed.observed_contracts == %{}
  end

  test "rejects post-state evidence from a different browser session", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, "/webmcp/rooms/skill-uplift")
    first_session = bootstrap(view, room)
    invoke_v1(view, room, first_session)

    invocation =
      Domain.list_invocations!(
        query: [filter: [room_id: room.id], sort: [started_at: :desc], limit: 1]
      )
      |> List.first()

    second_session = bootstrap(view, room)

    events_before =
      Domain.list_room_events!(query: [filter: [room_id: room.id], sort: [sequence: :asc]])

    html =
      render_hook(view, "webmcp_poststate_observed", %{
        "room_id" => room.id,
        "browser_session_id" => second_session.id,
        "invocation_id" => invocation.id,
        "post_state" => %{}
      })

    assert html =~ "post-state observation must come from the invocation browser session"

    assert length(Domain.list_room_events!(query: [filter: [room_id: room.id]])) ==
             length(events_before)
  end

  test "rejects a stale or forged tool revision before invocation", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, "/webmcp/rooms/skill-uplift")
    session = bootstrap(view, room)

    html =
      render_hook(view, "webmcp_invocation_begin", %{
        "room_id" => room.id,
        "browser_session_id" => session.id,
        "invocation_epoch" => invocation_epoch(view),
        "request_uuid" => Ash.UUID.generate(),
        "tool_name" => "uplift_current_skill_v2",
        "contract_sha256" => String.duplicate("0", 64),
        "arguments" => %{"instructions" => "bypass the current revision"}
      })

    assert html =~ "invoked tool name and contract must match the current desired revision"
    assert Domain.list_invocations!(query: [filter: [room_id: room.id]]) == []
  end

  defp bootstrap(view, room) do
    client_instance_id = Ash.UUID.generate()

    html =
      render_hook(view, "webmcp_bootstrap", %{
        "room_id" => room.id,
        "client_instance_id" => client_instance_id,
        "webmcp_supported" => true,
        "user_agent_digest" => Digest.sha256("test-browser")
      })

    assert html =~ "WebMCP connected"

    Domain.list_browser_sessions!(
      query: [filter: [room_id: room.id], sort: [connected_at: :desc], limit: 1]
    )
    |> List.first()
  end

  defp invoke_v1(view, room, session) do
    revision = desired_revision(room)

    _accepted_html =
      render_hook(view, "webmcp_invocation_begin", %{
        "room_id" => room.id,
        "browser_session_id" => session.id,
        "invocation_epoch" => invocation_epoch(view),
        "request_uuid" => Ash.UUID.generate(),
        "tool_name" => revision.name,
        "contract_sha256" => revision.contract_sha256,
        "arguments" => %{"instructions" => "clarify the workflow"}
      })

    invocation = latest_invocation(room)

    render_hook(view, "webmcp_execute", %{
      "invocation_id" => invocation.id,
      "invocation_epoch" => invocation_epoch(view)
    })

    awaiting_html = render_async(view)
    assert awaiting_html =~ "Awaiting Visible State"
    html = observe_latest_poststate(view, room, session)

    assert html =~ "Raw handler result"
    assert html =~ "success"
    assert html =~ "Visible postcondition failed"
    assert html =~ "CANDIDATE_EMPTY"
    assert Domain.get_room_by_id!(room.id).status == :failed
    assert Domain.get_room_by_id!(room.id).candidate_markdown == nil
  end

  defp observe_latest_poststate(view, room, session) do
    room = Domain.get_room_by_id!(room.id)

    invocation =
      Domain.list_invocations!(
        query: [filter: [room_id: room.id], sort: [started_at: :desc], limit: 1]
      )
      |> List.first()

    render_hook(view, "webmcp_poststate_observed", %{
      "room_id" => room.id,
      "browser_session_id" => session.id,
      "invocation_epoch" => invocation_epoch(view),
      "invocation_id" => invocation.id,
      "post_state" => %{
        "ui_revision" => room.ui_revision,
        "source" => %{"present" => true, "sha256" => room.source_sha256},
        "candidate" => %{
          "present" => is_binary(room.candidate_markdown),
          "sha256" => room.candidate_sha256
        }
      }
    })
  end

  defp desired_revision(room) do
    Domain.list_tool_revisions!(
      query: [
        filter: [room_id: room.id, generation: room.desired_tool_generation, status: :desired],
        limit: 1
      ]
    )
    |> List.first()
  end

  defp latest_invocation(room) do
    Domain.list_invocations!(
      query: [filter: [room_id: room.id], sort: [started_at: :desc], limit: 1]
    )
    |> List.first()
  end

  defp invocation_epoch(view) do
    {:ok, socket} = Phoenix.LiveView.Debug.socket(view.pid)
    socket.assigns.invocation_epoch
  end
end
