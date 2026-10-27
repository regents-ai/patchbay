defmodule PatchbayWeb.KnownFixReadTest do
  @moduledoc """
  Anyone may read the known fixes with no sign-in: a site's list and one fix
  in full, each with how many agents said it worked, and never who asked or
  who reported.
  """

  use PatchbayWeb.ConnCase, async: true

  alias Patchbay.Assist.Decision
  alias Patchbay.Assist.KnownFixes

  @fix "siwa-body-changed"

  # Two agents' word on the fix, as Patchbay keeps it, with the private parts
  # a decision holds: who acted, for whom, under which pairing and session.
  setup do
    private = %{
      acting_agent_id: Ash.UUID.generate(),
      beneficiary_profile_id: Ash.UUID.generate(),
      pairing_id: Ash.UUID.generate(),
      human_account_id: 4242,
      visitor_key: "visitor-key-kept-private",
      goal: "goal-kept-private",
      error: "error-kept-private"
    }

    decisions =
      for result <- [:worked, :did_not_work] do
        Ash.Seed.seed!(
          Decision,
          Map.merge(private, %{
            site: "patchbay.help",
            asked_from: :fix,
            choice: @fix,
            confidence: 0.9,
            model: "test-model",
            result: result,
            reported_at: DateTime.utc_now()
          })
        )
      end

    %{private: private, decisions: decisions}
  end

  test "a signed-out caller lists a site's known fixes, counted and nothing private",
       %{conn: conn, private: private, decisions: decisions} do
    conn = get(conn, "/known-fixes", %{"site" => "https://siwa.regents.sh/skill.md"})
    body = json_response(conn, 200)

    assert body["site"] == "regents.sh"

    assert Enum.map(body["known_fixes"], & &1["fix_id"]) ==
             Enum.map(KnownFixes.for_site("regents.sh"), & &1.id)

    fix = Enum.find(body["known_fixes"], &(&1["fix_id"] == @fix))
    assert fix["evidence"]["agents_said_it_worked"] == 1
    assert fix["evidence"]["agents_said_it_did_not_work"] == 1

    # A fix's own page answers the same with no sign-in.
    assert %{"fix_id" => @fix} = json_response(get(build_conn(), fix["url"]), 200)

    refute_private(conn.resp_body, private, decisions)
  end

  test "a signed-out caller reads one fix in full, counted and nothing private",
       %{conn: conn, private: private, decisions: decisions} do
    conn = get(conn, "/known-fixes/#{@fix}")
    body = json_response(conn, 200)
    known = KnownFixes.get(@fix)

    assert body["title"] == known.title
    assert body["steps"] == known.steps
    assert body["applies_when"] == known.applies_when
    assert body["evidence"]["agents_said_it_worked"] == 1
    assert body["evidence"]["agents_said_it_did_not_work"] == 1

    refute_private(conn.resp_body, private, decisions)
  end

  test "a fix nobody knows is not found, and a list needs a site", %{conn: conn} do
    assert %{"error" => %{"code" => "not_found"}} =
             json_response(get(conn, "/known-fixes/no-such-fix"), 404)

    assert %{"error" => %{"details" => ["site: " <> _]}} =
             json_response(get(build_conn(), "/known-fixes"), 422)
  end

  # The page tools hand an answer back whole only within 16 KiB, with room
  # left for their one-sentence summary.
  test "every list and every fix fits a page tool's answer whole", %{conn: conn} do
    sites = KnownFixes.all() |> Enum.flat_map(& &1.sites) |> Enum.uniq()

    for site <- sites do
      conn = get(conn, "/known-fixes", %{"site" => site})
      assert byte_size(conn.resp_body) <= 15 * 1024, "#{site}'s list is too long for a page tool"
    end

    for fix <- KnownFixes.all() do
      conn = get(build_conn(), "/known-fixes/#{fix.id}")
      assert byte_size(conn.resp_body) <= 15 * 1024, "#{fix.id} is too long for a page tool"
    end
  end

  defp refute_private(body, private, decisions) do
    for value <- Map.values(private), do: refute(body =~ to_string(value))
    for decision <- decisions, do: refute(body =~ decision.id)
    for key <- ~w(decision_id acting_agent_id pairing_id visitor_key), do: refute(body =~ key)
  end
end
