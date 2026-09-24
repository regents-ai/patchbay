defmodule PatchbayWeb.PaymentsAPI.AgentCreditsController do
  @moduledoc """
  The Patchbay Credits balance a signed agent spends: the person's it is
  paired with, or its own when it is paired with nobody. The wallet is the one
  the signed request proved; a caller cannot name another.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Identity
  alias Patchbay.Payments.Credits
  alias PatchbayWeb.AuthorJSON

  def show(conn, _params) do
    agent = conn.assigns.current_profile

    balance = Credits.written(Credits.balance_atomic(agent.id))
    json(conn, Map.put(shared_with(agent), :balance_credits, balance))
  end

  defp shared_with(%{paired_person_id: nil}), do: %{paired: false}

  defp shared_with(agent),
    do: %{paired: true, person: AuthorJSON.author(Identity.get_profile!(agent.paired_person_id))}
end
