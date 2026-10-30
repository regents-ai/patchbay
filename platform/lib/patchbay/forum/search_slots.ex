defmodule Patchbay.Forum.SearchSlots do
  @moduledoc """
  Room for a word search (`Patchbay.Forum.Report`'s `:search`) on the site's
  few database connections, so a crowd searching at once cannot take every one
  of them from the pages around it.

  At most two searches read at once. A search waits up to half a second for
  room, then reads inside one transaction whose statements PostgreSQL stops
  after two seconds (`statement_timeout`, set for that transaction only). A
  search that finds no room, runs out of time or is refused by the database
  answers `Patchbay.Forum.SearchUnavailable`, which every door turns into
  "try again shortly"; the kind of failure is logged.

  The room is a `NimblePool` of slots that hold nothing: it queues the waiting
  searches in order and takes back the slot of a search whose process ends.
  """

  use Ash.Resource.Preparation

  @behaviour NimblePool

  require Logger

  alias Patchbay.Forum.SearchUnavailable
  alias Patchbay.Repo

  @slots 2
  @wait_ms 500
  @statement_timeout "2s"

  @doc false
  def child_spec(_options) do
    %{
      id: __MODULE__,
      start:
        {NimblePool, :start_link,
         [[worker: {__MODULE__, nil}, pool_size: @slots, name: __MODULE__]]}
    }
  end

  @impl Ash.Resource.Preparation
  def prepare(query, _options, _context) do
    query
    |> Ash.Query.around_transaction(&in_slot/2)
    |> Ash.Query.before_action(fn query ->
      Repo.query!("SET LOCAL statement_timeout = '#{@statement_timeout}'")
      query
    end)
  end

  defp in_slot(query, read) do
    NimblePool.checkout!(
      __MODULE__,
      :search,
      fn _from, slot -> {answered(read, query), slot} end,
      @wait_ms
    )
  catch
    :exit, {:timeout, {NimblePool, :checkout, _}} -> unavailable(:no_slot)
  end

  defp answered(read, query) do
    case read.(query) do
      {:error, error} -> unavailable(error)
      answer -> answer
    end
  rescue
    # No connection came free in time to start the transaction.
    error in DBConnection.ConnectionError -> unavailable(error)
  end

  # The log names the kind of failure only, never the words searched for.
  defp unavailable(cause) do
    Logger.warning("Search unavailable", error_type: inspect(error_type(cause)))
    {:error, SearchUnavailable.exception(cause: cause)}
  end

  defp error_type(:no_slot), do: :no_slot
  defp error_type(%{errors: [error | _rest]}), do: error.__struct__
  defp error_type(error), do: error.__struct__

  @impl NimblePool
  def init_worker(pool_state), do: {:ok, :slot, pool_state}

  @impl NimblePool
  def handle_checkout(:search, _from, slot, pool_state), do: {:ok, slot, slot, pool_state}
end
