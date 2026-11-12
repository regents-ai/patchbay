defmodule Patchbay.Limits.LimitWrites do
  @moduledoc """
  Holds each writer to the `:allowance` named in `Patchbay.Limits`, as in
  ash-template, and, with `:address_allowance`, the client address the write
  came from as well, which the caller passes as `context: %{client_key: key}`
  (`PatchbayWeb.ClientAddress.visitor_key/1`). A write counts when it is
  saved, never while it is typed. The
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
      if admitted?(changeset, opts, actor),
        do: changeset,
        else:
          Ash.Changeset.add_error(
            changeset,
            Spent.exception(field: opts[:field], message: opts[:message])
          )
    end)
  end

  defp admitted?(changeset, opts, actor) do
    Limits.spend(opts[:allowance], Limits.writer(actor)) == :ok and
      address_admitted?(changeset, opts[:address_allowance])
  end

  defp address_admitted?(_changeset, nil), do: true

  defp address_admitted?(%{context: %{client_key: key}}, allowance),
    do: Limits.spend(allowance, key) == :ok
end
