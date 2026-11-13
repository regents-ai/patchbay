defmodule Patchbay.Offers.Scanner do
  @moduledoc """
  One pass over Patchbay's market: its placements, their terminations, every
  lease bought and every lease settled, each written once as the chain gave
  it. It follows the Keyfleet reader that `chain-events` describes.

  Each pass reads the head, reads again the last 300 blocks already recorded
  (one minute of Base), then reads on up to the head in stretches of at most
  10,000 blocks. A stretch the node will not answer whole is asked for again
  in halves, down to single blocks. Each piece's rows and the cursor's move
  are written in one transaction, only while the cursor still stands where
  this pass left it and is not stopped; pages hear about new rows after it
  commits. Nothing above the head this pass read is asked for, so a node that
  is behind makes a shorter pass, never missing history.

  The second reading is how a change in the chain's history shows up: a row
  read again that differs from the one recorded, or a recorded row whose block
  no longer has the hash it was recorded with, stops the reading at that
  block. Nothing recorded is rewritten; a person corrects the record and clears
  the stop (`mix patchbay.offers clear-stop`).
  """

  require Logger

  alias Patchbay.Offers

  alias Patchbay.Offers.{
    Diverged,
    Events,
    Lease,
    Placement,
    Settlement,
    Termination
  }

  @rescan_blocks 300
  @max_range 10_000
  @system %{role: :system}
  @kinds [placement: Placement, termination: Termination, lease: Lease, settlement: Settlement]

  @doc """
  Runs one pass with `client` over the market at `market` on `chain_id`.

  Returns `:ok` once the cursor has reached the head, `:moved` when someone
  else moved or stopped the cursor during the pass, `{:stopped, block}` while
  the reading is stopped at a disagreement, and `{:error, reason}` when the
  chain could not be read, the cursor then standing after the last piece
  recorded.
  """
  @spec pass(module(), pos_integer(), String.t()) ::
          :ok | :moved | {:stopped, non_neg_integer()} | {:error, term()}
  def pass(client, chain_id, market) do
    case cursor(chain_id, market) do
      %{rescan_from: nil} = cursor -> scan(client, cursor)
      %{rescan_from: block} -> {:stopped, block}
    end
  end

  defp cursor(chain_id, market) do
    Offers.get_cursor!(chain_id, market) ||
      Offers.open_cursor!(
        %{chain_id: chain_id, market: market, next_block: Offers.from_block()},
        actor: @system
      )
  end

  defp scan(client, cursor) do
    with {:ok, head} <- client.head(),
         {:ok, cursor} <- reread(client, cursor, head),
         {:ok, cursor} <- read_forward(client, cursor, head) do
      :telemetry.execute(
        [:patchbay, :indexer, :lag],
        %{blocks: max(head.number - (cursor.next_block - 1), 0)},
        %{indexer: "offers", chain_id: cursor.chain_id}
      )

      :ok
    else
      {:diverged, block} -> stop(cursor, block)
      {:moved, _block} -> :moved
      {:error, reason} -> {:error, reason}
    end
  end

  # Each piece is checked against what is recorded before anything new in it
  # is recorded; the cursor stays where it is.
  defp reread(client, cursor, head) do
    from = max(Offers.from_block(), cursor.next_block - @rescan_blocks)
    to = min(cursor.next_block - 1, head.number)

    each_piece(client, cursor, from, to, fn piece_from, piece_to, rows, cursor ->
      with :ok <- still_on_chain(client, cursor, rows, piece_from, piece_to),
           do: write_piece(rows, cursor, cursor.next_block, head)
    end)
  end

  # Reads on from the cursor to the head, a stretch at a time; each piece
  # moves the cursor past itself as it is recorded.
  defp read_forward(client, cursor, head) do
    from = cursor.next_block
    to = min(head.number, from + @max_range - 1)

    if to < from do
      write_piece([], cursor, from, head)
    else
      with {:ok, cursor} <-
             each_piece(client, cursor, from, to, fn _from, piece_to, rows, cursor ->
               write_piece(rows, cursor, piece_to + 1, head)
             end) do
        if to < head.number, do: read_forward(client, cursor, head), else: {:ok, cursor}
      end
    end
  end

  # Reads `from..to` in chain order. A stretch the node will not answer whole
  # is asked for again in halves, and each answered piece is handled before the
  # next is asked for. A node that does not answer at all ends the pass.
  defp each_piece(_client, cursor, from, to, _handle) when to < from, do: {:ok, cursor}

  defp each_piece(client, cursor, from, to, handle) do
    case client.logs(cursor.market, Events.topics(), from, to) do
      {:ok, logs} ->
        handle.(from, to, Events.rows(cursor.chain_id, logs), cursor)

      {:error, :unavailable} ->
        {:error, :unavailable}

      {:error, _refused} when from < to ->
        middle = div(from + to, 2)

        with {:ok, cursor} <- each_piece(client, cursor, from, middle, handle),
             do: each_piece(client, cursor, middle + 1, to, handle)

      {:error, reason} ->
        {:error, {:block_unanswered, from, reason}}
    end
  end

  # A piece's rows and the cursor's move are made together or not at all, and
  # pages hear about the rows only once they are committed.
  defp write_piece(rows, cursor, next_block, head) do
    Patchbay.Repo.transact(fn ->
      with {:ok, notifications} <- record(rows),
           {:ok, cursor, more} <- advance(cursor, next_block, head) do
        {:ok, {cursor, more ++ notifications}}
      end
    end)
    |> case do
      {:ok, {cursor, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, cursor}

      {:error, failure} ->
        failure(failure, cursor)
    end
  end

  defp record(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn {kind, fields}, {:ok, notifications} ->
      case @kinds[kind]
           |> Ash.Changeset.for_create(:record, fields, actor: @system)
           |> Ash.create(return_notifications?: true, rollback_on_error?: false) do
        {:ok, _row, more} -> {:cont, {:ok, more ++ notifications}}
        {:error, error} -> {:halt, {:error, {fields.block_number, error}}}
      end
    end)
  end

  defp advance(cursor, next_block, head) do
    case Offers.advance_cursor(
           cursor,
           %{
             from: cursor.next_block,
             next_block: next_block,
             head_block: head.number,
             head_block_hash: head.hash,
             observed_at: DateTime.utc_now()
           },
           actor: @system,
           rollback_on_error?: false,
           return_notifications?: true
         ) do
      {:error, error} -> {:error, {:cursor, error}}
      advanced -> advanced
    end
  end

  # A row read again that disagrees with the one recorded stops the reading
  # at the earlier of the block it was read from and the one it was recorded
  # from. A cursor someone else moved ends the pass quietly.
  defp failure({block, %{errors: errors} = error}, _cursor) when is_integer(block) do
    case for(%Diverged{recorded_block: recorded} <- errors, do: recorded) do
      [] -> {:error, error}
      recorded -> {:diverged, Enum.min([block | recorded])}
    end
  end

  defp failure({:cursor, %{errors: errors} = error}, cursor) do
    if Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)),
      do: {:moved, cursor.next_block},
      else: {:error, error}
  end

  defp failure(other, _cursor), do: {:error, other}

  # A recorded row the second reading no longer finds means the chain changed
  # only when its block no longer has the hash it was recorded with;
  # otherwise the node answered inconsistently and the pass is retried.
  defp still_on_chain(client, cursor, rows, from, to) do
    seen = MapSet.new(rows, fn {_kind, fields} -> {fields.transaction_hash, fields.log_index} end)
    window = %{chain_id: cursor.chain_id, market: cursor.market, from: from, to: to}

    @kinds
    |> Enum.flat_map(fn {_kind, resource} ->
      resource |> Ash.Query.for_read(:in_blocks, window) |> Ash.read!()
    end)
    |> Enum.reject(&MapSet.member?(seen, {&1.transaction_hash, &1.log_index}))
    |> Enum.map(&{&1.block_number, &1.block_hash})
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn {block, recorded_hash}, :ok ->
      case client.block_hash(block) do
        {:ok, ^recorded_hash} -> {:halt, {:error, {:log_missing_from_block, block}}}
        {:ok, _other_hash} -> {:halt, {:diverged, block}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp stop(cursor, block) do
    %{rescan_from: stopped_at} = Offers.stop_cursor!(cursor, block, actor: @system)

    Logger.error(
      "Agent offers: the market's record disagrees with the chain at block #{block}; " <>
        "reading is stopped at block #{stopped_at}. Correct the record, then run " <>
        "mix patchbay.offers clear-stop."
    )

    {:stopped, stopped_at}
  end
end
