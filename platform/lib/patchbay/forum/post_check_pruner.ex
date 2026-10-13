defmodule Patchbay.Forum.PostCheckPruner do
  @moduledoc """
  Forgets, once a day, the words of every post that was turned away more
  than a month ago. The reading itself stays, with its digest, its finding
  and any ruling, so a person's count and the moderators' record are
  unchanged. A cut a moderator made one of Jev's examples is kept apart from
  these words and stays until a moderator takes it out.
  """
  use Oban.Worker, queue: :post_checks, max_attempts: 3

  alias Patchbay.Forum.PostCheck

  @kept_days 30

  @doc "How many days a turned-away post's words are kept."
  @spec kept_days() :: pos_integer()
  def kept_days, do: @kept_days

  @impl Oban.Worker
  def perform(_job) do
    PostCheck
    |> Ash.Query.for_read(:forgettable, %{
      before: DateTime.add(DateTime.utc_now(), -@kept_days, :day)
    })
    # Patchbay's own housekeeping of its own rows.
    |> Ash.bulk_update!(:forget, %{}, authorize?: false, strategy: :atomic)

    :ok
  end
end
