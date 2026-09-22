defmodule PatchbayWeb.IdentityAPI.Pairing do
  @moduledoc """
  What every agent door answers when an agent sends a person's pairing code:
  the signed agent API and the hosted `pair_with_person` tool, each once it
  has proven the wallet.
  """

  alias Patchbay.Identity.Pairing
  alias Patchbay.Payments.Credits
  alias PatchbayWeb.AuthorJSON

  @doc """
  Pairs wallet author `agent` with the person whose `code` it sent: the
  person, and the balance the two now share, or why nothing was paired.
  """
  @spec run(struct(), term()) :: {:ok, map()} | {:error, map()}
  def run(agent, code) do
    case Pairing.pair(agent, code) do
      {:ok, person} ->
        {:ok,
         %{
           paired: true,
           person: AuthorJSON.author(person),
           balance_credits: Credits.written(Credits.balance_atomic(person.id)),
           next_action:
             "You now share this person's Patchbay Credits. When the balance runs low, ask them to buy more on their Patchbay profile page."
         }}

      {:error, :code_unknown} ->
        code_unknown()

      {:error, _failure} ->
        {:error,
         %{
           paired: false,
           problem_code: "not_paired",
           error: "That wallet could not be paired. Nothing was paired."
         }}
    end
  end

  @doc "What a code that is unknown, used or past its ten minutes is answered with."
  @spec code_unknown() :: {:error, map()}
  def code_unknown do
    {:error,
     %{
       paired: false,
       problem_code: "code_unknown",
       error:
         "That code is unknown, already used or more than ten minutes old. Nothing was paired.",
       next_action:
         "Ask the person for a new code; they make one with Pair an agent on their Patchbay profile page."
     }}
  end
end
