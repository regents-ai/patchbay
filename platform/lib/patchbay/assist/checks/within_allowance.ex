defmodule Patchbay.Assist.Checks.WithinAllowance do
  @moduledoc """
  A free run may open only under the grant the allowance gives its
  connection and its person right now: the connection's own free fix while
  it has one, then a signed-in person's. A request that names any other
  grant, or arrives once both are used up, opens nothing.
  """

  use Ash.Policy.SimpleCheck

  alias Patchbay.Assist.Allowance

  @impl true
  def describe(_opts), do: "the free fix is one the connection or the signed-in person has left"

  @impl true
  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    grant = Ash.Changeset.get_argument(changeset, :grant)
    visitor_key = Ash.Changeset.get_argument(changeset, :visitor_key)

    is_binary(visitor_key) and Allowance.grant(visitor_key, actor) == {:ok, grant}
  end

  def match?(_actor, _context, _opts), do: false
end
