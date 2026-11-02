defmodule Patchbay.Points.Hidden do
  @moduledoc """
  When moderation holds a post back or takes it down, queues the return of
  the Points it earned (`Patchbay.Points.Correction`), in the same
  transaction as moderation's word.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, post ->
      if post.visibility != :published,
        do: Oban.insert!(Patchbay.Points.Correction.new(%{kind: opts[:kind], id: post.id}))

      {:ok, post}
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
