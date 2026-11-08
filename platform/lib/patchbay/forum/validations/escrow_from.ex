defmodule Patchbay.Forum.Validations.EscrowFrom do
  @moduledoc """
  The states a bounty's money may move from in one escrow action
  (`Patchbay.Forum.Types.EscrowStatus` draws them). In an atomic update it is
  checked against the stored value inside the UPDATE statement, so a writer
  holding an older copy of the report can never put one state over a later
  one: the statement finds the row has moved on and refuses. `nil` among the
  states is a bounty paid for and not yet handed to Base.

  It is not Ash's `data_one_of`, because a stored NULL has to answer like any
  other state: `NULL IN (...)` is never true in SQL, so a step that starts
  from nil could never pass, and `NULL NOT IN (...)` is never true either, so
  a step that does not could let a nil row through.
  """

  use Ash.Resource.Validation

  import Ash.Expr

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def init(opts) do
    case opts[:from] do
      [_ | _] -> {:ok, opts}
      _none -> {:error, "names no state to move from"}
    end
  end

  @impl true
  def supports(_opts), do: [Ash.Changeset]

  @impl true
  def validate(changeset, opts, _context) do
    status = Ash.Changeset.get_data(changeset, :escrow_status)
    if status in opts[:from], do: :ok, else: {:error, refusal(status, opts)}
  end

  # Written so a stored NULL answers as plainly as any value: `NULL NOT IN
  # (...)` is neither true nor false in SQL, which would let the row through.
  @impl true
  def atomic(_changeset, opts, _context) do
    {:atomic, [:escrow_status], moved_on(opts[:from]),
     expr(
       error(^InvalidAttribute, %{
         field: :escrow_status,
         value: escrow_status,
         message: ^message(opts)
       })
     )}
  end

  @impl true
  def describe(opts), do: [message: message(opts), vars: []]

  defp moved_on(from) do
    case {nil in from, Enum.reject(from, &is_nil/1)} do
      {true, []} -> expr(not is_nil(escrow_status))
      {true, states} -> expr(not is_nil(escrow_status) and escrow_status not in ^states)
      {false, states} -> expr(is_nil(escrow_status) or escrow_status not in ^states)
    end
  end

  defp refusal(status, opts),
    do: InvalidAttribute.exception(field: :escrow_status, value: status, message: message(opts))

  defp message(opts) do
    "has moved on: this step starts only from " <>
      Enum.map_join(opts[:from], ", ", &if(is_nil(&1), do: "not handed over", else: &1))
  end
end
