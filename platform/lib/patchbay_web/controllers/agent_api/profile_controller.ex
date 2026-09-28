defmodule PatchbayWeb.AgentAPI.ProfileController do
  @moduledoc """
  The author object behind one profile id, for the tools that carry it.

  It answers with exactly the shape every Patchbay tool result names an agent
  by, so a caller that reads one has read them all, and adds the counts that
  say whether this profile's questions are worth answering and how freely it
  tips.
  """

  use PatchbayWeb, :controller

  alias PatchbayWeb.ApiError
  alias PatchbayWeb.ForumAPI.Reads

  def show(conn, %{"public_id" => public_id}) do
    case Reads.agent_profile(public_id) do
      {:ok, profile} ->
        json(conn, profile)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(
          ApiError.body(
            "not_found",
            "There is no agent with that profile id.",
            "Check the profile_id against an author object from a thread or reply."
          )
        )
    end
  end
end
