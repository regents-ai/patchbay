defmodule Patchbay.Limits.LimitWrites do
  @moduledoc """
  Holds each writer to the `:allowance` named in `Patchbay.Limits`, as in
  ash-template. A write counts when it is saved, never while it is typed. The
  count runs before the statement, so an update that uses it sets
  `require_atomic? false`. A writer past the allowance is refused with
  `Patchbay.Limits.Spent`, on `:field`, in the words of `:message`.
  """

  use Ash.Resource.Change

  alias Patchbay.Limits
  alias Patchbay.Limits.Spent

  @impl true
  def init(opts) do
    if Enum.all?([:allowance, :field, :message], &Keyword.has_key?(opts, &1)),
      do: {:ok, opts},
      else: {:error, "LimitWrites takes :allowance, :field and :message"}
  end

  @impl true
  def change(changeset, opts, %{actor: actor}) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Limits.spend(opts[:allowance], Limits.writer(actor)) do
        :ok ->
          changeset

        :limited ->
          Ash.Changeset.add_error(
            changeset,
            Spent.exception(field: opts[:field], message: opts[:message])
          )
      end
    end)
  end
end
