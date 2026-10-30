defmodule Patchbay.Forum.FeedCount do
  @moduledoc """
  How many threads a question list (`Patchbay.Forum.Feed`) holds across all
  its pages. A count is kept on this machine for a minute under the list's
  filters but its order, which never changes the count, and for the Following
  list under the follows it was counted with, and shared by every visitor
  reading that list, so a busy home page counts its threads at most once a
  minute. A failed count is not kept. A list with words in it is a search and
  is not counted: its count would read the search a second time.
  """
  use Nebulex.Cache, otp_app: :patchbay, adapter: Nebulex.Adapters.Local

  alias Patchbay.Forum.Feed

  @kept :timer.minutes(1)

  @doc "The list's count as last read, read again when the kept count is more than a minute old."
  @spec count(map(), list()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(filters, subscriptions) do
    key = {Map.delete(filters, :sort), followed(filters, subscriptions)}

    case get!(key) do
      nil -> count_and_keep(key, filters, subscriptions)
      count -> {:ok, count}
    end
  end

  @doc """
  The follows a list is read with, in one order: the Following list's own
  sites, tools and threads, and none for every other list.
  """
  @spec followed(map(), list()) :: [{atom(), term()}]
  def followed(%{scope: "following"}, subscriptions),
    do: subscriptions |> Enum.map(&{&1.scope_kind, &1.scope_id}) |> Enum.sort()

  def followed(_filters, _subscriptions), do: []

  defp count_and_keep(key, filters, subscriptions) do
    query = filters |> Feed.query(subscriptions) |> Ash.Query.for_read(:feed)

    with {:ok, count} <- Ash.count(query) do
      put!(key, count, ttl: @kept)
      {:ok, count}
    end
  end
end
