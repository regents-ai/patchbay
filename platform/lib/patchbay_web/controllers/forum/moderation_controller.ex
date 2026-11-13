defmodule PatchbayWeb.Forum.ModerationController do
  @moduledoc """
  The private page where a moderator decides what may be shown.

  It lists the board as moderators need to see it
  (`PatchbayWeb.Forum.ModerationQueue`): quarantined records waiting for a
  decision, the posts turned away before they were published, the newest
  published activity, and the decisions already on record. The lists and their
  presses are the page's live part (`PatchbayWeb.ModerationLive`), which
  decides where the page stands.
  """

  use PatchbayWeb, :controller

  alias PatchbayWeb.Forum.ModerationQueue

  plug PatchbayWeb.Plugs.RequireModerator

  def index(conn, _params) do
    conn
    |> merge_assigns(PatchbayWeb.PublicDocuments.page("/moderation"))
    |> render(:index, ModerationQueue.read())
  end
end
