defmodule Patchbay.Points.Record do
  @moduledoc """
  Offers Regent Points what may earn, inside the transaction that made it, so
  something that rolls back offers nothing. Points decides whether it earns;
  while a rule is off nothing is queued.

  `rules` are the rules the record may earn, `kind` is what Points calls it
  and `key` the attribute that names it: one published post or one Offer bid
  is one source, however many rules it counts for.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      for rule <- opts[:rules] do
        RegentPoints.record_event!(
          %{
            rule_id: rule,
            source_app: Patchbay.Points.app(),
            source_kind: opts[:kind],
            source_event_key: Map.fetch!(record, opts[:key])
          },
          actor: %{role: :system}
        )
      end

      {:ok, record}
    end)
  end
end
