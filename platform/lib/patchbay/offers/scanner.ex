defmodule Patchbay.Offers.Scanner do
  @moduledoc """
  One pass over Patchbay's market: its placements, their terminations, every
  lease bought and every lease settled, each saved once as the chain gave it.
  It follows the Keyfleet reader that `chain-events` describes, and keeps
  what it saved first, as Autolaunch's covered-call reader does.

  Each pass reads the head, reads again the last 300 blocks already recorded
  (one minute of Base), then reads on up to the head in stretches of at most
  10,000 blocks. A stretch the node will not answer whole is asked for again
  in halves, down to single blocks. Each piece's new rows and the cursor's
  move are written in one transaction, only while the cursor still stands
  where this pass left it; pages hear about new rows after it commits.
  Nothing above the head this pass read is asked for, so a node that is
  behind makes a shorter pass, never missing history.

  A row is saved by the first pass that reads its event, and kept as first
  saved. Each piece is checked against the saved rows before anything new in
  it is saved. The chain disagrees with the record when an event read again
  differs from its saved row, when a saved transaction is read from another
  block, or when a saved row is no longer found and its block no longer has
  the hash it was saved with, or is gone. Then the saved rows stay as they
  are, nothing more of that transaction is saved, and the pass logs one
  warning naming the market and the transaction and reads on. A saved row
  missing from a block whose hash is unchanged is the node answering
  inconsistently: the pass ends with an error and is tried again.

  Nothing remembers a warning from one pass to the next, so a transaction
  whose block is still among the 300 read again is named again by the next
  pass.
  """

  require Logger

  alias Patchbay.Offers
  alias Patchbay.Offers.{Events, Lease, Placement, Settlement, Termination}

  @rescan_blocks 300
  @max_range 10_000
  @system %{role: :system}
  @kinds [placement: Placement, termination: Termination, lease: Lease, settlement: Settlement]

  @doc """
  Runs one pass with `client` over the market at `market` on `chain_id`.

  Returns `:ok` once the cursor has reached the head, `:moved` when another
  pass moved the cursor during this one, and `{:error, reason}` when the
  chain could not be read, the cursor then standing after the last piece
  recorded.
  """
  @spec pass(module(), pos_integer(), String.t()) :: :ok | :moved | {:error, term()}
  def pass(client, chain_id, market) do
    # The transactions this pass has named in a warning already.
    reading = %{cursor: cursor(chain_id, market), named: MapSet.new()}

    with {:ok, head} <- client.head(),
         {:ok, reading} <- reread(client, reading, head),
         {:ok, %{cursor: cursor}} <- read_forward(client, reading, head) do
      :telemetry.execute(
        [:patchbay, :indexer, :lag],
        %{blocks: max(head.number - (cursor.next_block - 1), 0)},
        %{indexer: "offers", chain_id: cursor.chain_id}
      )

      :ok
    end
  end

  defp cursor(chain_id, market) do
    Offers.get_cursor!(chain_id, market) ||
      Offers.open_cursor!(
        %{chain_id: chain_id, market: market, next_block: Offers.from_block()},
        actor: @system
      )
  end

  # The blocks already recorded, read again; the cursor stays where it is.
  defp reread(client, %{cursor: cursor} = reading, head) do
    from = max(Offers.from_block(), cursor.next_block - @rescan_blocks)
    to = min(cursor.next_block - 1, head.number)

    each_piece(client, reading, from, to, fn piece_from, piece_to, rows, reading ->
      piece(client, reading, {piece_from, piece_to}, rows, reading.cursor.next_block, head)
    end)
  end

  # Reads on from the cursor to the head, a stretch at a time; each piece
  # moves the cursor past itself as it is recorded.
  defp read_forward(client, %{cursor: cursor} = reading, head) do
    from = cursor.next_block
    to = min(head.number, from + @max_range - 1)

    read = fn piece_from, piece_to, rows, reading ->
      piece(client, reading, {piece_from, piece_to}, rows, piece_to + 1, head)
    end

    cond do
      to < from ->
        with {:ok, cursor} <- write_piece([], cursor, from, head),
             do: {:ok, %{reading | cursor: cursor}}

      to < head.number ->
        with {:ok, reading} <- each_piece(client, reading, from, to, read),
             do: read_forward(client, reading, head)

      true ->
        each_piece(client, reading, from, to, read)
    end
  end

  # Reads `from..to` in chain order. A stretch the node will not answer whole
  # is asked for again in halves, and each answered piece is handled before the
  # next is asked for. A node that does not answer at all ends the pass.
  defp each_piece(_client, reading, from, to, _handle) when to < from, do: {:ok, reading}

  defp each_piece(client, %{cursor: cursor} = reading, from, to, handle) do
    case client.logs(cursor.market, Events.topics(), from, to) do
      {:ok, logs} ->
        handle.(from, to, Events.rows(cursor.chain_id, logs), reading)

      {:error, :unavailable} ->
        {:error, :unavailable}

      {:error, _refused} when from < to ->
        middle = div(from + to, 2)

        with {:ok, reading} <- each_piece(client, reading, from, middle, handle),
             do: each_piece(client, reading, middle + 1, to, handle)

      {:error, reason} ->
        {:error, {:block_unanswered, from, reason}}
    end
  end

  # A piece's rows checked against the saved ones; then its new rows and the
  # cursor's move are written, and each transaction the chain now disagrees
  # with is named, once in the pass.
  defp piece(client, %{cursor: cursor, named: named}, blocks, rows, next_block, head) do
    saved = saved(cursor, blocks, rows)

    with {:ok, gone} <- gone(client, saved, rows, blocks),
         {fresh, differs} = compare(rows, saved, gone),
         {:ok, cursor} <- write_piece(fresh, cursor, next_block, head) do
      differs
      |> MapSet.difference(named)
      |> Enum.sort()
      |> Enum.each(fn transaction ->
        Logger.warning(
          "Agent offers: transaction #{transaction} on the market #{cursor.market} no " <>
            "longer matches the chain; the rows saved first are kept"
        )
      end)

      {:ok, %{cursor: cursor, named: MapSet.union(named, differs)}}
    end
  end

  # The saved rows a piece is checked against: those of its blocks, and every
  # row of the transactions it read, wherever they were saved.
  defp saved(cursor, {from, to}, rows) do
    where = %{
      chain_id: cursor.chain_id,
      market: cursor.market,
      from: from,
      to: to,
      transactions:
        rows |> Enum.map(fn {_kind, fields} -> fields.transaction_hash end) |> Enum.uniq()
    }

    read = &(&1 |> Ash.Query.for_read(:recorded, where) |> Ash.read!())
    read.(Placement) ++ read.(Termination) ++ read.(Lease) ++ read.(Settlement)
  end

  # The transactions of the piece's saved rows that the reading no longer
  # finds, in blocks whose hash has changed or that are gone.
  defp gone(client, saved, rows, {from, to}) do
    read = MapSet.new(rows, fn {_kind, fields} -> event(fields) end)

    saved
    |> Enum.filter(&(&1.block_number in from..to//1 and not MapSet.member?(read, event(&1))))
    |> Enum.group_by(& &1.block_number)
    |> Enum.sort()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {block, missing}, {:ok, gone} ->
      case moved_on(client, block, missing) do
        {:ok, transactions} -> {:cont, {:ok, MapSet.union(gone, transactions)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # The transactions of a block's saved rows the reading no longer finds,
  # once the block's hash has changed or it is gone. A row missing from a
  # block whose hash is unchanged means the node left its log out, and the
  # pass is tried again.
  defp moved_on(client, block, missing) do
    case client.block_hash(block) do
      {:ok, hash} ->
        if Enum.any?(missing, &(&1.block_hash == hash)),
          do: {:error, {:log_missing_from_block, block}},
          else: {:ok, MapSet.new(missing, & &1.transaction_hash)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The rows read that are not saved yet, and the transactions the chain
  # disagrees with: those `gone` found, those with an event saved with other
  # values, and those saved from another block. Nothing more of those is
  # saved. A row of a saved transaction read from the block it was saved from
  # is one an earlier reading left out, and is saved.
  defp compare(rows, saved, gone) do
    by_event = Map.new(saved, &{event(&1), &1})
    saved_in = Map.new(saved, &{&1.transaction_hash, &1.block_hash})

    differs =
      for {_kind, fields} = row <- rows,
          differs?(row, by_event[event(fields)], saved_in[fields.transaction_hash]),
          into: gone,
          do: fields.transaction_hash

    fresh =
      for {_kind, fields} = row <- rows,
          not Map.has_key?(by_event, event(fields)),
          not MapSet.member?(differs, fields.transaction_hash),
          do: row

    {fresh, differs}
  end

  defp differs?(_row, nil, nil), do: false
  defp differs?({_kind, fields}, nil, saved_from), do: fields.block_hash != saved_from

  defp differs?({kind, fields}, %resource{} = saved, _saved_from) do
    @kinds[kind] != resource or
      not Enum.all?(fields, fn {key, read} -> same?(Map.fetch!(saved, key), read) end)
  end

  defp same?(%Decimal{} = saved, %Decimal{} = read), do: Decimal.equal?(saved, read)
  defp same?(saved, read), do: saved == read

  defp event(row), do: {row.transaction_hash, row.log_index}

  # A piece's new rows and the cursor's move are made together or not at all,
  # and pages hear about the rows only once they are committed. A cursor
  # another pass moved first ends this pass quietly.
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

      {:error, {:cursor, %{errors: errors} = error}} ->
        if Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)),
          do: :moved,
          else: {:error, error}

      {:error, error} ->
        {:error, error}
    end
  end

  defp record(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn {kind, fields}, {:ok, notifications} ->
      case @kinds[kind]
           |> Ash.Changeset.for_create(:record, fields, actor: @system)
           |> Ash.create(return_notifications?: true, rollback_on_error?: false) do
        {:ok, _row, more} -> {:cont, {:ok, more ++ notifications}}
        {:error, error} -> {:halt, {:error, error}}
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
end
