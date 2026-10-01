defmodule Patchbay.Assist.Checks.WithinAgentAllowance do
  @moduledoc """
  A free run for an agent may open only for the SIWA-signed agent asking,
  while its wallet has a free fix left today and the site has not given out
  today's. Anyone else, or an agent whose free fixes are used, opens nothing.
  """

  use Ash.Policy.SimpleCheck

  alias Patchbay.Assist.Allowance

  @impl true
  def describe(_opts), do: "the free fix is one the signed-in agent has left"

  @impl true
  def match?(%{authentication_origin: :wallet} = agent, %{changeset: %Ash.Changeset{}}, _opts),
    do: Allowance.agent_grant(agent) == {:ok, :agent}

  def match?(_actor, _context, _opts), do: false
end
