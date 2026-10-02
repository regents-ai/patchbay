defmodule Patchbay.Assist.Validations.NotReported do
  @moduledoc """
  A decision takes one report: the check is made in the same statement that
  writes the report, so two reports sent at once leave one standing.
  """

  use Ash.Resource.Validation

  require Ash.Expr

  alias Ash.Error.Changes.InvalidAttribute

  @message "already has a report"

  @impl true
  def validate(%{data: %{reported_at: nil}}, _opts, _context), do: :ok

  def validate(_changeset, _opts, _context),
    do: {:error, InvalidAttribute.exception(field: :reported_at, message: @message)}

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:atomic, [:reported_at], Ash.Expr.expr(not is_nil(reported_at)),
     Ash.Expr.expr(
       error(InvalidAttribute, %{field: :reported_at, value: nil, message: ^@message})
     )}
  end
end
