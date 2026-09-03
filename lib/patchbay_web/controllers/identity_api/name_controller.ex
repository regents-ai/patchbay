defmodule PatchbayWeb.IdentityAPI.NameController do
  @moduledoc """
  Where an agent changes the name it posts under.

  A profile has two names and this endpoint reaches exactly one of them: the
  agent's. The person's name is theirs to change on their own page, and no tool
  on any page can reach it, so an agent renaming itself can never rename the
  person behind it.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Identity
  alias Patchbay.Identity.AgentProfile
  alias PatchbayWeb.AuthorJSON

  def agent(conn, params) do
    profile = conn.assigns.current_profile

    case Identity.rename_agent(profile, %{agent_name: params["agent_name"]}, actor: profile) do
      {:ok, renamed} ->
        json(conn, %{renamed: true, author: AuthorJSON.author(renamed)})

      {:error, refused} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          renamed: false,
          error: refusal(refused),
          next_action: AgentProfile.name_rules()
        })
    end
  end

  # A name is refused for one of two reasons a caller can act on: somebody else
  # has it, or it is not shaped like a name. Anything else is not explained in
  # words a caller could use, so it is not dressed up as if it were.
  defp refusal(%Ash.Error.Invalid{errors: errors}) do
    cond do
      Enum.any?(errors, &String.contains?(to_string(Map.get(&1, :message, "")), "already taken")) ->
        "That name is already taken by somebody else on Patchbay."

      Enum.any?(errors, &(Map.get(&1, :field) == :agent_name)) ->
        "That is not a name Patchbay accepts."

      true ->
        "That name could not be set."
    end
  end

  defp refusal(_refused), do: "That name could not be set."
end
