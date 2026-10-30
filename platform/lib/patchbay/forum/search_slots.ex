defmodule Patchbay.Forum.SearchSlots do
  @moduledoc """
  Room for a text search on the site's few database connections, so a crowd
  searching at once cannot take every one of them from the pages around it.
  Every read that looks for typed words takes a place: the word search
  (`Patchbay.Forum.Report`'s `:search`), the question list with words in it
  (`Patchbay.Forum.Feed`), and the site and tool matches (`:find` on
  `Patchbay.Forum.Site` and `Patchbay.Forum.Tool`).

  At most two such reads run at once. A read waits up to half a second for a
  place, then runs inside one transaction whose statements PostgreSQL stops
  after two seconds (`statement_timeout`, set for that transaction only).

  Only a crowd makes a search busy: no place free in time, no connection free
  in time, or PostgreSQL stopping the read at two seconds. Each answers
  `Patchbay.Forum.SearchUnavailable`, which every door turns into "try again
  shortly", and the kind is logged. Any other error is a fault and passes
  through unchanged.

  A read that takes a place must not run inside another transaction: its
  time limit would hold for the outer transaction too, and a busy read would
  roll the outer one back. No caller does so.

  The room is a `NimblePool` of slots that hold nothing: it queues the waiting
  reads in order and takes back the slot of a read whose process ends.
  """

  use Ash.Resource.Preparation

  @behaviour NimblePool

  require Logger

  alias Patchbay.DatabaseBusy
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

  @doc "A read action whose every read takes a place."
  @impl Ash.Resource.Preparation
  def prepare(query, _options, _context), do: hold(query)

  @doc "One read of `query` that takes a place."
  @spec hold(Ash.Query.t()) :: Ash.Query.t()
  def hold(query) do
    Ash.Query.around_transaction(query, fn query, read -> run(fn -> read.(query) end) end)
  end

  @doc """
  Runs `read`, which answers `{:ok, ...}` or `{:error, error}`, in a place
  and a transaction of its own. Busy answers `SearchUnavailable`; any other
  answer is `read`'s own.
  """
  @spec run((-> tuple())) :: tuple()
  def run(read) do
    NimblePool.checkout!(
      __MODULE__,
      :search,
      fn _from, slot -> {in_transaction(read), slot} end,
      @wait_ms
    )
  catch
    :exit, {:timeout, {NimblePool, :checkout, _}} -> unavailable(:no_slot)
  end

  defp in_transaction(read) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL statement_timeout = '#{@statement_timeout}'")

      case read.() do
        {:error, error} -> Repo.rollback(error)
        answer -> answer
      end
    end)
    |> case do
      {:ok, answer} -> answer
      {:error, error} -> failed(error)
    end
  rescue
    # No connection came free in time to start the transaction.
    DBConnection.ConnectionError -> unavailable(:no_connection)
  end

  defp failed(error) do
    case DatabaseBusy.kind(error) do
      nil -> {:error, error}
      kind -> unavailable(kind)
    end
  end

  # The log names the kind only, never the words searched for.
  defp unavailable(kind) do
    Logger.warning("Search unavailable", error_type: inspect(kind))
    {:error, SearchUnavailable.exception(cause: kind)}
  end

  @impl NimblePool
  def init_worker(pool_state), do: {:ok, :slot, pool_state}

  @impl NimblePool
  def handle_checkout(:search, _from, slot, pool_state), do: {:ok, slot, slot, pool_state}
end
