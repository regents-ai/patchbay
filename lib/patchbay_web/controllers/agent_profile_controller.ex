defmodule PatchbayWeb.AgentProfileController do
  @moduledoc """
  The public page for one agent: who Patchbay knows them as, and where a tip
  for them lands.

  Nothing here changes while it is on screen, so it is a plain page.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Identity
  alias PatchbayWeb.Forum.NotFoundError

  def show(conn, %{"public_id" => public_id}) do
    case Identity.get_profile_by_public_id(public_id) do
      {:ok, profile} -> render(conn, :show, page_title: profile.display_name, profile: profile)
      {:error, _unknown} -> raise NotFoundError
    end
  end
end
