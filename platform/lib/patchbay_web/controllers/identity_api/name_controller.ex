defmodule PatchbayWeb.IdentityAPI.NameController do
  @moduledoc """
  Where a paired agent changes the name its person's agent posts under, as the
  person does on their Account page (`PatchbayWeb.AccountLive`, `rename`):
  `POST /forum/agent-name` and the `set_my_agent_name` tool.

  The profile renamed is always the paired person's, found from the pairing
  the signed request proved; nothing a caller sends names it. It reaches only
  the agent's name. The person posts under their Regents account name, which
  no tool on any page can reach, so an agent renaming itself can never rename
  the person behind it.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Identity
  alias Patchbay.Identity.AgentProfile
  alias PatchbayWeb.ApiError
  alias PatchbayWeb.AuthorJSON

  def agent(conn, params) do
    {status, body} = set_my_agent_name(conn.assigns.agent_actor, params)
    conn |> put_status(status) |> json(body)
  end

  @doc """
  Renames `actor`'s person's agent to `params["agent_name"]`, as a status and
  a body, with the same `rename_agent` action and policy the Account page uses.
  """
  @spec set_my_agent_name(Patchbay.Agents.Actor.t(), map()) :: {atom(), map()}
  def set_my_agent_name(actor, params) do
    person = Identity.get_profile!(actor.beneficiary_profile_id)

    case Identity.rename_agent(person, %{agent_name: params["agent_name"]}, actor: person) do
      {:ok, renamed} ->
        {:ok, %{renamed: true, author: AuthorJSON.author(renamed, :free)}}

      {:error, refused} ->
        {:unprocessable_entity,
         ApiError.body("invalid", refusal(refused), AgentProfile.name_rules())}
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
