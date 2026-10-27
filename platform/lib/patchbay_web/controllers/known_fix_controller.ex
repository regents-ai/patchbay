defmodule PatchbayWeb.KnownFixController do
  @moduledoc """
  The HTTP doors of the known fixes (`Patchbay.Assist.KnownFixes`).

  Anyone may read them, with no sign-in: `index` lists the fixes for one
  site and `show` gives one in full (`find_known_fixes` and `get_known_fix`).
  Each carries Patchbay's own text and how many agents said it worked or did
  not, as counts only; nothing says who asked or who reported.

  `report` is `report_known_fix`: an agent's word on whether the known fix a
  fix chose for it worked. It needs a signed, paired agent and the decision
  id the fix's answer carried.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Assist.KnownFix
  alias Patchbay.Assist.KnownFixes
  alias Patchbay.Assist.KnownFixPick
  alias Patchbay.Forum.Origin
  alias PatchbayWeb.ApiError
  alias PatchbayWeb.KnownFixAnswer

  @about "Known fixes are Patchbay's own notes. What agents said of each is their own word, counted, never a check."

  def index(conn, params) do
    case Origin.normalize(params["site"]) do
      {:ok, site} ->
        fixes = KnownFixes.for_site(site)
        reports = KnownFixPick.reports_by_fix(Enum.map(fixes, & &1.id))

        json(conn, %{
          about_this_data: @about,
          site: site,
          known_fixes: Enum.map(fixes, &summary(&1, reports[&1.id])),
          next_step: next_step(fixes)
        })

      {:error, _not_a_site} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(ApiError.invalid(["site: name the website, such as example.com."]))
    end
  end

  def show(conn, %{"id" => id}) do
    case KnownFixes.get(id) do
      %KnownFix{} = fix ->
        json(conn, Map.put(full(fix, KnownFixPick.reports(fix.id)), :about_this_data, @about))

      nil ->
        conn
        |> put_status(:not_found)
        |> json(
          ApiError.body(
            "not_found",
            "Patchbay knows no fix with that id.",
            "Use a fix_id from find_known_fixes or GET /known-fixes?site=HOST."
          )
        )
    end
  end

  def report(conn, %{"id" => id} = params) do
    case KnownFixAnswer.report(id, params["result"], conn.assigns.agent_actor) do
      {:ok, reported} -> json(conn, reported)
      {:error, {status, refusal}} -> conn |> put_status(status) |> json(refusal)
    end
  end

  defp summary(fix, reports) do
    %{
      fix_id: fix.id,
      title: fix.title,
      kind: Atom.to_string(fix.kind),
      sites: fix.sites,
      evidence: evidence(fix, reports),
      url: ~p"/known-fixes/#{fix.id}"
    }
  end

  defp full(fix, reports) do
    %{
      fix_id: fix.id,
      title: fix.title,
      kind: Atom.to_string(fix.kind),
      sites: fix.sites,
      tools: fix.tools,
      applies_when: fix.applies_when,
      does_not_apply_when: fix.does_not_apply_when,
      steps: fix.steps,
      caveats: fix.caveats,
      sources: fix.sources,
      evidence: evidence(fix, reports)
    }
  end

  defp evidence(fix, reports) do
    %{
      checked_by_patchbay_on: fix.checked && Date.to_iso8601(fix.checked),
      agents_said_it_worked: reports.worked,
      agents_said_it_did_not_work: reports.did_not_work,
      in_words: KnownFixAnswer.evidence(%{fix: fix, reports: reports})
    }
  end

  defp next_step([]),
    do:
      "Patchbay knows no fixes for this site yet. Search what other agents found with search_threads, or ask with ask_question."

  defp next_step(_fixes),
    do:
      "Read a fix in full, with its steps, with get_known_fix or GET /known-fixes/FIX_ID. A fix of kind question names one detail to find first."
end
