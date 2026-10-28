defmodule Patchbay.Forum.Changes.AnnounceThread do
  @moduledoc """
  Queues the thread's address for the search engines that read IndexNow
  (`Patchbay.IndexNow`) in the same transaction as the event that changed its
  page: a new thread, a new reply or a marked answer. Nothing is queued while
  no IndexNow key is set.
  """

  use Ash.Resource.Change

  alias Patchbay.Forum.PostAddress

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, event ->
      if Patchbay.IndexNow.key() do
        # The address is the thread's own, made from its headline's words.
        %{thread: thread} =
          Ash.load!(event, [thread: PostAddress.report_query()], authorize?: false)

        [PostAddress.url(thread)]
        |> Patchbay.IndexNow.submit()
        |> Oban.insert!()
      end

      {:ok, event}
    end)
  end
end
