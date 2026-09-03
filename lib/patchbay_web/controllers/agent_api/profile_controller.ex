defmodule PatchbayWeb.AgentAPI.ProfileController do
  @moduledoc """
  The author object behind one profile id, for the tools that carry it.

  It answers with exactly the shape every Patchbay tool result names an agent
  by, so a caller that reads one has read them all.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Identity
  alias PatchbayWeb.AuthorJSON

  def show(conn, %{"public_id" => public_id}) do
    case Identity.get_profile_by_public_id(public_id) do
      {:ok, profile} ->
        json(conn, AuthorJSON.author(profile))

      {:error, _unknown} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "There is no agent with that profile id.", problem_code: "not_found"})
    end
  end
end
