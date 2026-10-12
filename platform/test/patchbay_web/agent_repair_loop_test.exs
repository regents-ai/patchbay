defmodule PatchbayWeb.AgentRepairLoopTest do
  @moduledoc """
  The whole loop, driven with nothing an agent would not actually be holding.

  Everything the report is filed with comes out of the result the room handed
  back for the agent's signed call. No digest is computed here, because a language model
  calling these tools could not compute one either.
  """

  # The worker reads application settings, so this file runs alone.
  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Forum
  alias Patchbay.Forum.PatchbayAgent
  alias Patchbay.Forum.RepairAttempt
  alias Patchbay.Forum.Report
  alias Patchbay.Forum.RoomMirror
  alias Patchbay.Identity
  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.{Digest, RoomEntrance}
  alias PatchbayWeb.Plugs.CurrentProfile
  alias PatchbayWeb.SignedAgent

  setup do
    put_setting(:demo_fallback, true)
    put_setting(:agent_repairs, true)
    SignedAgent.stub_siwa()

    :ok
  end

  test "an agent can get a verified repair using only the tool result it received", %{conn: conn} do
    # The room is opened by the person it belongs to, who alone may change it.
    owner =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:repair-loop-owner",
        wallet_address: "0x" <> String.duplicate("7", 40)
      })

    room = Domain.create_seeded_room!(RoomEntrance.personal_slug(owner))
    agent = SignedAgent.pair!(owner)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> CurrentProfile.sign_in(owner.id)
      |> get(~p"/webmcp/rooms/#{room.slug}")

    {:ok, view, _html} = live(conn)
    session = bootstrap(view, room)

    result = call_the_broken_tool(agent, room, session)

    # What the call came to, and the one value the agent needs to report it.
    assert %{"effective_status" => "verified_failure", "receipt" => receipt} = result

    # The report carries the receipt and the agent's own words. Nothing else.
    filed =
      build_conn()
      |> SignedAgent.sign(agent)
      |> post(
        "/forum/reports",
        Jason.encode!(%{
          "receipt" => receipt,
          "note" => "It said it worked, but the page did nothing.",
          "client_request_id" => Ecto.UUID.generate()
        })
      )

    assert %{"report_id" => report_id, "verified" => true, "receipt_status" => "verified"} =
             json_response(filed, 201)

    report = Ash.get!(Report, report_id, load: [tool: :site])
    revision = desired_revision(room)

    assert report.verified
    assert report.tool.site.origin == RoomMirror.origin()
    assert report.tool.name == revision.name
    assert report.tool.contract_sha256 == revision.contract_sha256
    assert report.arguments_sha256 == latest_invocation(room).arguments_sha256

    # One pass of the worker that reads the board.
    assert {:ok, %RepairAttempt{} = attempt} = PatchbayAgent.sweep()
    assert attempt.status == :published
    assert attempt.report_id == report.id

    repaired = Domain.get_room_by_id!(room.id)
    assert repaired.desired_tool_generation == 2
    assert desired_revision(repaired).name == "uplift_current_skill_v2"

    [reply] = Forum.list_replies_for_report!(report.id).results
    assert reply.note =~ "Please retry with uplift_current_skill_v2."
  end

  # One signed call to the tool the page is offering, taken to its visible
  # verdict, and answered with the result the agent receives.
  defp call_the_broken_tool(agent, room, session) do
    revision = desired_revision(room)

    %{"invocation_id" => invocation_id} =
      room_request(agent, room, session, "invocations", %{
        "tool_name" => revision.name,
        "contract_sha256" => revision.contract_sha256,
        "request_uuid" => Ash.UUID.generate(),
        "arguments" => %{"instructions" => "make the greeting warmer"},
        "pre_state" => visible_state(room)
      })
      |> json_response(200)

    room_request(agent, room, session, "invocations/#{invocation_id}/observations", %{
      "post_state" => visible_state(room)
    })
    |> json_response(200)
  end

  # What the page is showing, as the page reports it.
  defp visible_state(room) do
    current = Domain.get_room_by_id!(room.id)

    %{
      "ui_revision" => current.ui_revision,
      "source" => %{"present" => true, "sha256" => current.source_sha256},
      "candidate" => %{
        "present" => is_binary(current.candidate_markdown),
        "sha256" => current.candidate_sha256
      }
    }
  end

  defp room_request(agent, room, session, path, params) do
    build_conn()
    |> SignedAgent.sign(agent)
    |> post(
      "/api/agent/rooms/#{room.slug}/#{path}",
      Jason.encode!(Map.put(params, "page_evidence", session.page_evidence))
    )
  end

  # The page's browser session as its bootstrap reply hands it over.
  defp bootstrap(view, room) do
    html =
      render_hook(view, "webmcp_bootstrap", %{
        "room_id" => room.id,
        "client_instance_id" => Ash.UUID.generate(),
        "webmcp_supported" => true,
        "user_agent_digest" => Digest.sha256("test-browser")
      })

    assert html =~ "WebMCP connected"
    assert_reply(view, %{"page_evidence" => page_evidence})
    %{page_evidence: page_evidence}
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

  defp put_setting(key, value) do
    previous = Application.get_env(:patchbay, key)
    Application.put_env(:patchbay, key, value)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:patchbay, key),
        else: Application.put_env(:patchbay, key, previous)
    end)
  end
end
