defmodule PatchbayWeb.ForumAPI.SiteRefreshController do
  @moduledoc """
  A paired agent's "Refresh this site" (`PatchbayWeb.SiteRefreshLive`): a new
  picture of a site and a new check of its WebMCP tools, through the same
  `PatchbayWeb.Forum.SiteChecks.refresh/3` and its rules: once the last
  picture is a day old, and twenty asks in ten minutes per visitor. The agent
  is a visitor under its pairing (`POST /forum/sites/{site}/refresh` and the
  `refresh_site` tool).
  """

  use PatchbayWeb, :controller

  alias Patchbay.Forum
  alias PatchbayWeb.ApiError
  alias PatchbayWeb.Forum.Board
  alias PatchbayWeb.Forum.SiteChecks

  def create(conn, %{"site" => site}),
    do: send_answer(conn, refresh_site(conn.assigns.agent_actor, site))

  defp send_answer(conn, {status, body}), do: conn |> put_status(status) |> json(body)

  @doc "Asks for a new picture and check of `site` for `actor`, as a status and a body."
  @spec refresh_site(Patchbay.Agents.Actor.t(), String.t()) :: {atom(), map()}
  def refresh_site(actor, ref) do
    case Board.fetch_site_ref(ref) do
      {:ok, found} ->
        site = Forum.get_site_by_origin!(found.origin, load: [:refresh_due?])
        current = SiteChecks.current(found.origin)

        case SiteChecks.refresh(site, current, "pairing:" <> actor.pairing_id) do
          {:ok, _check} ->
            {:accepted,
             %{
               site: found.origin,
               state: "refreshing",
               next_step:
                 "Read the site's tools again with read_tool_catalog or read_site_directory once the check is done, in a minute or two."
             }}

          {:limited, _check} ->
            {:too_many_requests,
             ApiError.body(
               "rate_limited",
               "You've refreshed a lot of sites just now. Try again in a few minutes.",
               "Nothing was asked. Wait a few minutes, then send it again."
             )}

          {:not_ready, check} ->
            not_ready(found.origin, SiteChecks.refresh_state(site, check))
        end

      :error ->
        {:not_found,
         ApiError.body(
           "not_found",
           "Patchbay has no page for that site.",
           "Name a site from read_site_directory, by its domain, such as example.com."
         )}
    end
  end

  defp not_ready(origin, :refreshing) do
    {:conflict,
     ApiError.body(
       "refresh_running",
       "#{origin} is being refreshed now.",
       "Read its tools again in a minute or two."
     )}
  end

  defp not_ready(origin, {:fresh, at}) do
    again = DateTime.shift(at, day: 1)

    {:conflict,
     ApiError.body(
       "refreshed_recently",
       "#{origin} was refreshed in the last day.",
       "Refresh it again after refresh_after.",
       %{refresh_after: again}
     )}
  end
end
