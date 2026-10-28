defmodule Patchbay.Forum.Validations.NoFutureUpdates do
  @moduledoc """
  A dated update says when something became known, so none is dated after
  the moment it is written.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @message "an update cannot be dated in the future"

  @impl true
  def init(opts) do
    case opts[:attribute] do
      attribute when is_atom(attribute) and not is_nil(attribute) -> {:ok, opts}
      _ -> {:error, "`:attribute` is required"}
    end
  end

  @impl true
  def validate(changeset, opts, _context) do
    now = DateTime.utc_now()
    updates = Ash.Changeset.get_attribute(changeset, opts[:attribute]) || []

    if Enum.all?(updates, &(DateTime.compare(&1.at, now) != :gt)),
      do: :ok,
      else: {:error, InvalidAttribute.exception(field: opts[:attribute], message: @message)}
  end

  @impl true
  def describe(_opts), do: [message: @message, vars: []]
end
