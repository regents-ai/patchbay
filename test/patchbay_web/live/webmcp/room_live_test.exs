defmodule PatchbayWeb.WebMCP.RoomLiveTest do
  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Config
  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.{CandidateGenerator, Digest, Fixtures}
  alias PatchbayWeb.WebMCP.RoomLive.Presenter

  setup %{conn: conn} do
    room = Domain.create_seeded_room!("room-#{System.unique_integer([:positive])}")

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

  test "renders the seeded room with stable editor and state identifiers", %{
    conn: conn,
    room: room
  } do
    {:ok, view, html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")

    assert html =~ "Skill Uplift Studio"
    assert has_element?(view, "#patchbay-source-editor")
    assert has_element?(view, "#patchbay-candidate-editor")
    assert has_element?(view, "#patchbay-room-state[data-ui-revision=\"0\"]")
    assert has_element?(view, "[id^=patchbay-webmcp-]")
    assert html =~ "Candidate editor"
    assert html =~ "empty"
  end

  test "the guide above the goal carries all three agent prompts and the board link", %{
    conn: conn,
    room: room
  } do
    {:ok, view, html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")

    assert view
           |> element("#patchbay-prompt-uplift[readonly]")
           |> render() =~
             "Call uplift_current_skill_v1 with instructions: make the greeting warmer."

    assert view
           |> element("#patchbay-prompt-repair[readonly]")
           |> render() =~
             "That tool reported success but changed nothing on the page. Call report_tool_problem about it, and pass the patchbay_receipt from the result as the receipt."

    assert view
           |> element("#patchbay-prompt-retry[readonly]")
           |> render() =~
             "The site&#39;s tools changed. Inspect the current tools and retry the uplift."

    assert view
           |> element("#patchbay-board-link[href=\"/sites\"]")
           |> render() =~ "See tool reports from other sites"

    assert html =~ "This page hands a browser agent a tool that is broken on purpose."
    assert html =~ "Observed G2"
    assert :binary.match(html, "patchbay-guide") < :binary.match(html, "patchbay-goal-title")
  end

  test "names the active tool and discloses that the Source Skill is sent to OpenAI", %{
    conn: conn,
    room: room
  } do
    {:ok, view, html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")

    assert has_element?(view, "#patchbay-active-tool", desired_revision(room).name)

    assert html =~
             "When you or an agent asks for an uplift, Patchbay sends the Source Skill below and the request instructions to OpenAI."

    assert html =~
             "contract, what the handler returned, and the short fingerprints of what this page was showing."
  end

  test "shows the invocation arguments beside the raw handler result", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
    session = bootstrap(view, room)
    invoke_v1(view, room, session)

    assert has_element?(view, "#patchbay-invocation-arguments", "instructions")
    assert has_element?(view, "#patchbay-invocation-arguments", "clarify the workflow")
    assert has_element?(view, "#patchbay-handler-response", "reported_success")
  end

  test "states the demo fallback sentence required by the specification", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
    session = bootstrap(view, room)
    invoke_v1(view, room, session)

    assert has_element?(
             view,
             "#patchbay-fallback-warning",
             "Demo fallback used because live inference was unavailable."
           )

    assert render(view) =~ "This candidate has not been evaluated on real tasks."
  end

  test "shows both tool names and contract digests before human approval", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
    session = bootstrap(view, room)
    invoke_v1(view, room, session)

    render_click(view, "request_repair")
    render_async(view, 2_000)

    proposal =
      Domain.list_repair_proposals!(
        query: [filter: [room_id: room.id], sort: [inserted_at: :desc], limit: 1]
      )
      |> List.first()

    source_revision = Domain.get_tool_revision!(proposal.source_tool_revision_id)
    candidate_revision = Domain.get_tool_revision!(proposal.candidate_tool_revision_id)

    assert has_element?(view, "#patchbay-tool-swap", source_revision.name)
    assert has_element?(view, "#patchbay-tool-swap", candidate_revision.name)

    assert has_element?(
             view,
             "#patchbay-tool-swap code[title=\"#{source_revision.contract_sha256}\"]"
           )

    assert has_element?(
             view,
             "#patchbay-tool-swap code[title=\"#{candidate_revision.contract_sha256}\"]"
           )
  end

  test "an agent can ask for the repair, and asking twice does not start a second one", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
    session = bootstrap(view, room)
    invoke_v1(view, room, session)

    render_hook(view, "webmcp_request_repair", %{
      "room_id" => room.id,
      "browser_session_id" => session.id
    })

    assert_reply(view, %{
      "status" => "repair_requested",
      "human_approval_required" => true,
      "detail" => detail
    })

    assert detail =~ "cannot approve or publish one"
    assert Domain.get_room_by_id!(room.id).status == :diagnosing

    render_hook(view, "webmcp_request_repair", %{
      "room_id" => room.id,
      "browser_session_id" => session.id
    })

    assert_reply(view, %{"status" => "already_in_progress", "human_approval_required" => true})

    html = render_async(view, 2_000)
    assert html =~ "CONTRACT DIFF"
    assert html =~ "DETERMINISTIC CANARY"
    assert html =~ "Approve &amp; hot-swap"

    proposal = latest_proposal(room)
    assert proposal.status == :ready_for_approval

    # The proposal is waiting for a person, so a further request only says so.
    render_hook(view, "webmcp_request_repair", %{"room_id" => room.id})
    assert_reply(view, %{"status" => "proposal_ready", "human_approval_required" => true})

    assert Domain.get_room_by_id!(room.id).desired_tool_generation == 1
  end

  test "an agent asking before any failure is told there is nothing to repair", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
    session = bootstrap(view, room)

    render_hook(view, "webmcp_request_repair", %{
      "room_id" => room.id,
      "browser_session_id" => session.id
    })

    assert_reply(view, %{"status" => "no_failed_invocation", "human_approval_required" => true})

    assert Domain.get_room_by_id!(room.id).status == :ready
    assert Domain.list_repair_proposals!(query: [filter: [room_id: room.id]]) == []

    html =
      render_hook(view, "webmcp_request_repair", %{
        "room_id" => Ash.UUID.generate(),
        "browser_session_id" => session.id
      })

    assert html =~ "event belongs to another room"
    assert Domain.get_room_by_id!(room.id).status == :ready
  end

  test "no event a page tool can send approves or publishes a repair", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
    session = bootstrap(view, room)
    invoke_v1(view, room, session)

    render_hook(view, "webmcp_request_repair", %{
      "room_id" => room.id,
      "browser_session_id" => session.id
    })

    render_async(view, 2_000)
    proposal = latest_proposal(room)
    assert proposal.status == :ready_for_approval

    invocation = latest_invocation(room)
    revision = desired_revision(room)

    # Every event the page's tools can send, replayed against a proposal that is
    # waiting for a person. None of them is allowed to approve or publish it.
    for {event, params} <- browser_events(room, session, invocation, revision, view) do
      render_hook(view, event, params)
    end

    proposal = Domain.get_repair_proposal!(proposal.id)
    assert proposal.status == :ready_for_approval
    assert proposal.approved_by == nil
    room_after = Domain.get_room_by_id!(room.id)
    assert room_after.desired_tool_generation == 1
    refute room_after.status in [:publishing, :repaired, :verified]

    # The human control is the only way through.
    html = render_click(view, "approve_repair")
    assert html =~ "Generation 2"
    assert Domain.get_repair_proposal!(proposal.id).status == :published
    assert Domain.get_repair_proposal!(proposal.id).approved_by == "owner"
  end

  test "accepts an uploaded Markdown Skill and recomputes the source digest", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
    source = room.source_markdown <> "\n\n## Uploaded note\n"

    upload = skill_upload(view, "skill.md", source)
    assert render_upload(upload, "skill.md") =~ "Upload file"

    html = render_submit(view |> form("#patchbay-skill-upload-form"))

    assert html =~ Digest.sha256(source)
    assert Domain.get_room_by_id!(room.id).source_sha256 == Digest.sha256(source)
    assert Domain.get_room_by_id!(room.id).source_markdown == source
  end

  test "rejects a file that is not a Markdown Skill", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
    original = Domain.get_room_by_id!(room.id).source_sha256

    upload = skill_upload(view, "skill.zip", "PK\x03\x04 not markdown", "application/zip")

    assert {:error, [[_ref, :not_accepted]]} = render_upload(upload, "skill.zip")

    assert render(view) =~
             "Only Markdown Skill files ending in .md or .markdown can be uploaded."

    assert Domain.get_room_by_id!(room.id).source_sha256 == original
  end

  test "rejects a Markdown file over the Skill size limit", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
    original = Domain.get_room_by_id!(room.id).source_sha256
    oversize = String.duplicate("a", Digest.max_artifact_bytes() + 1)

    upload = skill_upload(view, "huge.md", oversize)

    assert {:error, [[_ref, :too_large]]} = render_upload(upload, "huge.md")

    assert render(view) =~ "That file is larger than 64 KB. Upload a smaller Markdown Skill."
    assert Domain.get_room_by_id!(room.id).source_sha256 == original
  end

  test "rejects a Markdown file that is not readable text", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
    original = Domain.get_room_by_id!(room.id).source_sha256

    upload = skill_upload(view, "binary.md", <<0xFF, 0xFE, 0x00, 0xFF>>)
    render_upload(upload, "binary.md")

    html = render_submit(view |> form("#patchbay-skill-upload-form"))

    assert html =~ "That file is not readable text. Upload a Markdown Skill saved as UTF-8."
    assert Domain.get_room_by_id!(room.id).source_sha256 == original
  end

  test "rejects an empty Markdown file", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
    original = Domain.get_room_by_id!(room.id).source_sha256

    # The upload test client cannot chunk a zero-byte file, so this stands in for
    # a file with no Skill content in it.
    upload = skill_upload(view, "empty.md", "\n   \n")
    render_upload(upload, "empty.md")

    html = render_submit(view |> form("#patchbay-skill-upload-form"))

    assert html =~ "That file is empty. Upload a Markdown Skill with content in it."
    assert Domain.get_room_by_id!(room.id).source_sha256 == original
  end

  test "a forged upload event cannot change the Source Skill while the room is working", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
    session = bootstrap(view, room)
    invoke_v1(view, room, session)

    locked = Domain.get_room_by_id!(room.id)
    assert locked.status != :ready

    upload = skill_upload(view, "forged.md", locked.source_markdown <> "\n\n## Forged note\n")
    render_upload(upload, "forged.md")

    html = render_hook(view, "upload_skill", %{})

    assert html =~ "The Source Skill is locked while this room is working."
    assert has_element?(view, "#patchbay-upload-error[role=\"alert\"]")
    refute has_element?(view, "#patchbay-platform-error")
    assert Domain.get_room_by_id!(room.id).source_sha256 == locked.source_sha256
  end

  test "refuses Source Skill text that carries unstorable or hidden characters", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
    original = Domain.get_room_by_id!(room.id).source_sha256

    html =
      render_submit(view |> form("#patchbay-source-form"), %{
        "source_markdown" => room.source_markdown <> "\n\n## Note\0\n"
      })

    assert html =~ "That Skill text contains characters Patchbay cannot store."

    html =
      render_submit(view |> form("#patchbay-source-form"), %{
        "source_markdown" => room.source_markdown <> "\n\n## Note " <> <<0xE0041::utf8>> <> "\n"
      })

    assert html =~ "That Skill text contains hidden characters that do not show on screen."
    assert Domain.get_room_by_id!(room.id).source_sha256 == original
  end

  test "shortens an oversized evidence record before it reaches the page" do
    value = %{"instructions" => String.duplicate("a", 9_000)}

    html = render_component(&Presenter.evidence_text/1, value: value)

    assert html =~ "Shortened for display."
    refute html =~ String.duplicate("a", 9_000)
    assert byte_size(html) < 5_000
  end

  test "asks for a file when the upload control is submitted empty", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")

    html = render_submit(view |> form("#patchbay-skill-upload-form"))

    assert html =~ "Choose a Markdown Skill file before uploading."
  end

  test "shows a visible failure when live inference is unavailable", %{conn: conn, room: room} do
    without_live_inference(fn ->
      {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
      session = bootstrap(view, room)
      revision = desired_revision(room)

      render_hook(view, "webmcp_invocation_begin", %{
        "room_id" => room.id,
        "browser_session_id" => session.id,
        "invocation_epoch" => invocation_epoch(view),
        "request_uuid" => Ash.UUID.generate(),
        "tool_name" => revision.name,
        "contract_sha256" => revision.contract_sha256,
        "arguments" => %{"instructions" => "uplift without a model"}
      })

      invocation = latest_invocation(room)

      render_hook(view, "webmcp_execute", %{
        "invocation_id" => invocation.id,
        "invocation_epoch" => invocation_epoch(view)
      })

      html = render_async(view, 2_000)

      assert html =~ "Live inference failed"
      assert html =~ "The candidate was not presented as a successful completion."
      assert Domain.get_invocation!(invocation.id).effective_status == :errored
      assert Domain.get_room_by_id!(room.id).candidate_markdown == nil
    end)
  end

  # The health probe, the candidate generator, and this room all decide the
  # generation mode through Patchbay.Config, so flipping the switch has to move
  # all three of them together. The second half leaves the application setting
  # off, so the environment flag alone is what all three of them read.
  test "the demo fallback switch moves the health probe, the generator, and the room together",
       %{conn: conn, room: room} do
    without_live_inference(fn ->
      refute Config.demo_fallback?()

      assert json_response(get(build_conn(), ~p"/webmcp/health"), 200)["demo_fallback_enabled"] ==
               false

      assert {:error, {:model_generation_failed, :api_key_missing}} =
               CandidateGenerator.generate(room.source_markdown, %{
                 "instructions" => "uplift with the switch off"
               })

      {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
      session = bootstrap(view, room)
      revision = desired_revision(room)

      render_hook(view, "webmcp_invocation_begin", %{
        "room_id" => room.id,
        "browser_session_id" => session.id,
        "invocation_epoch" => invocation_epoch(view),
        "request_uuid" => Ash.UUID.generate(),
        "tool_name" => revision.name,
        "contract_sha256" => revision.contract_sha256,
        "arguments" => %{"instructions" => "uplift with the switch off"}
      })

      render_hook(view, "webmcp_execute", %{
        "invocation_id" => latest_invocation(room).id,
        "invocation_epoch" => invocation_epoch(view)
      })

      assert render_async(view, 2_000) =~ "Live inference failed"

      System.put_env("PATCHBAY_DEMO_FALLBACK", "true")

      assert Config.demo_fallback?()

      assert json_response(get(build_conn(), ~p"/webmcp/health"), 200)["demo_fallback_enabled"] ==
               true

      assert {:ok, %{fallback_used: true}} =
               CandidateGenerator.generate(room.source_markdown, %{
                 "instructions" => "uplift with the switch on"
               })

      render_click(view, "reset_demo")
      invoke_v1(view, room, bootstrap(view, room))

      assert has_element?(
               view,
               "#patchbay-fallback-warning",
               "Demo fallback used because live inference was unavailable."
             )
    end)
  end

  test "updates source digest through the same room page", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
    source = room.source_markdown <> "\n\n## Local note\n"

    html = render_submit(view |> form("#patchbay-source-form"), %{"source_markdown" => source})

    assert html =~ Digest.sha256(source)
    assert Domain.get_room_by_id!(room.id).source_sha256 == Digest.sha256(source)
  end

  test "locks the source once invocation evidence exists", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
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
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
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

    awaiting_html = render_async(view, 2_000)
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

  test "hands the agent a receipt for the call, bound to this browser", %{conn: conn, room: room} do
    conn = get(conn, ~p"/webmcp/rooms/#{room.slug}")
    forum_session_id = Plug.Conn.get_session(conn, "forum_session_id")
    {:ok, view, _html} = live(conn)
    session = bootstrap(view, room)
    revision = desired_revision(room)

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

    render_async(view, 2_000)

    assert_push_event(view, "patchbay:" <> _topic, %{"patchbay_receipt" => receipt})

    assert receipt == Domain.get_invocation!(invocation.id).receipt
    assert receipt =~ ~r/\A[A-Za-z0-9_-]{22}\z/

    # The receipt belongs to the browser that made the call, so a report quoting
    # it can be held against the identity the page issued.
    assert is_binary(forum_session_id)
    assert Domain.get_browser_session!(session.id).forum_session_id == forum_session_id
  end

  test "runs repair, human approval, observed generation, retry, and reset on one page", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")

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
    html = render_async(view, 2_000)

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

  test "an open page hot-swaps a tool the worker published on a report", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
    session = bootstrap(view, room)
    invoke_v1(view, room, session)

    file_verified_report!(room, session)

    # The worker runs outside this page's process, exactly as it does in the
    # deployed room.
    assert {:ok, %{status: :published}} = Patchbay.Forum.PatchbayAgent.sweep()

    publication_event = "patchbay:#{room.id}:publication_requested"
    toolset_event = "patchbay:#{room.id}:desired_toolset"
    v2 = desired_revision(Domain.get_room_by_id!(room.id))
    v2_name = v2.name

    html = render(view)

    assert_push_event(view, ^publication_event, %{"revision" => %{"name" => ^v2_name}})
    assert_push_event(view, ^toolset_event, %{"generation" => 2})

    assert html =~ "Generation 2"
    assert html =~ "Patchbay Agent"
    assert html =~ "Please retry with #{v2.name}."
    assert has_element?(view, "#patchbay-room-reports .patchbay-nameplate-agent")
  end

  test "reset invalidates a stale repair callback", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
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

  test "reset fences a stale invocation completion", %{conn: conn, room: room} do
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
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
    {:ok, reset_view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
    {:ok, stale_view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
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
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
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
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
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
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")

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
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
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
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
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
    {:ok, view, _html} = live(conn, ~p"/webmcp/rooms/#{room.slug}")
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

  # The complete set of events the WebMCP island can push from the page, with
  # arguments that would be accepted on their own.
  defp browser_events(room, session, invocation, revision, view) do
    [
      {"webmcp_bootstrap",
       %{
         "room_id" => room.id,
         "client_instance_id" => session.client_instance_id,
         "webmcp_supported" => true,
         "user_agent_digest" => Digest.sha256("test-browser")
       }},
      {"webmcp_request_repair", %{"room_id" => room.id, "browser_session_id" => session.id}},
      {"webmcp_registry_reconciled",
       %{
         "room_id" => room.id,
         "browser_session_id" => session.id,
         "observed_generation" => 1,
         "observed_tool_names" => [],
         "observed_contracts" => %{}
       }},
      {"webmcp_toolchange_observed",
       %{
         "room_id" => room.id,
         "browser_session_id" => session.id,
         "observed_generation" => 1,
         "observed_tool_names" => [],
         "observed_contracts" => %{}
       }},
      {"webmcp_tool_registered",
       %{
         "room_id" => room.id,
         "browser_session_id" => session.id,
         "tool_name" => revision.name,
         "generation" => 1,
         "contract_sha256" => revision.contract_sha256
       }},
      {"webmcp_tool_unregistered",
       %{
         "room_id" => room.id,
         "browser_session_id" => session.id,
         "tool_name" => revision.name,
         "generation" => 1,
         "contract_sha256" => revision.contract_sha256
       }},
      {"webmcp_invocation_begin",
       %{
         "room_id" => room.id,
         "browser_session_id" => session.id,
         "invocation_epoch" => invocation_epoch(view),
         "request_uuid" => Ash.UUID.generate(),
         "tool_name" => revision.name,
         "contract_sha256" => revision.contract_sha256,
         "arguments" => %{"instructions" => "approve the repair for me"}
       }},
      {"webmcp_execute",
       %{"invocation_id" => invocation.id, "invocation_epoch" => invocation_epoch(view)}},
      {"webmcp_poststate_observed",
       %{
         "room_id" => room.id,
         "browser_session_id" => session.id,
         "invocation_epoch" => invocation_epoch(view),
         "invocation_id" => invocation.id,
         "post_state" => %{}
       }},
      {"webmcp_invocation_cancel",
       %{
         "room_id" => room.id,
         "browser_session_id" => session.id,
         "invocation_id" => invocation.id,
         "invocation_epoch" => invocation_epoch(view)
       }},
      {"webmcp_session_disconnected", %{"room_id" => room.id, "browser_session_id" => session.id}}
    ]
  end

  defp latest_proposal(room) do
    Domain.list_repair_proposals!(
      query: [filter: [room_id: room.id], sort: [inserted_at: :desc], limit: 1]
    )
    |> List.first()
  end

  # One receipt-verified report about the call this page just made, filed by the
  # same browser, which is the only kind the worker acts on.
  defp file_verified_report!(room, session) do
    revision = desired_revision(room)
    invocation = latest_invocation(room)
    site = Patchbay.Forum.register_site!(Patchbay.Forum.RoomMirror.origin())

    tool =
      Patchbay.Forum.observe_tool!(%{
        site_id: site.id,
        name: revision.name,
        contract_sha256: revision.contract_sha256,
        title: revision.title,
        description: revision.description
      })

    report =
      Patchbay.Forum.file_report!(%{
        tool_id: tool.id,
        browser_session_id: Domain.get_browser_session!(session.id).forum_session_id,
        arguments_sha256: invocation.arguments_sha256,
        handler_result: %{"reported_success" => true},
        observed: %{"candidate_present" => false},
        verdict: :verified_failure,
        failure_code: "CANDIDATE_EMPTY",
        note: "It said it worked, but the page did nothing.",
        receipt: invocation.receipt
      })

    assert report.verified
    report
  end

  defp skill_upload(view, name, content, type \\ "text/markdown") do
    file_input(view, "#patchbay-skill-upload-form", :skill, [
      %{name: name, content: content, type: type, last_modified: 1_700_000_000_000}
    ])
  end

  # The room reads its live-inference settings at execution time, so the flags are
  # swapped for the duration of the block and restored afterwards.
  defp without_live_inference(fun) do
    previous_setting = Application.get_env(:patchbay, :demo_fallback)
    previous_flag = System.get_env("PATCHBAY_DEMO_FALLBACK")
    previous_key = System.get_env("OPENAI_API_KEY")

    Application.put_env(:patchbay, :demo_fallback, false)
    System.delete_env("PATCHBAY_DEMO_FALLBACK")
    System.delete_env("OPENAI_API_KEY")

    try do
      fun.()
    after
      Application.put_env(:patchbay, :demo_fallback, previous_setting)
      restore_env("PATCHBAY_DEMO_FALLBACK", previous_flag)
      restore_env("OPENAI_API_KEY", previous_key)
    end
  end

  defp restore_env(_name, nil), do: :ok
  defp restore_env(name, value), do: System.put_env(name, value)

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

    awaiting_html = render_async(view, 2_000)
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
