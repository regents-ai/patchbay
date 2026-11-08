defmodule Patchbay.Repo.Migrations.RefusedRefundsStillHeld do
  @moduledoc """
  A refund the chain refused moved no money, so a bounty written down as
  `refund_failed` is still held in escrow, and that state retires. Each such
  bounty is written back as `credited`: the refund sweep reads it again from
  then on and writes the refund if the contract has since sent it back, and it
  counts and ranks as held money again. `refund_failed` was only ever written
  over `credited` or itself, so `credited` is what the chain last confirmed.

  Written by hand: the column is text, so nothing in the schema changes. The
  count is printed in the release step. `down` changes nothing, since the code
  before this reads `credited` as it reads every held bounty.
  """

  use Ecto.Migration

  # The table is named in the schema the migrator is putting it in (`prefix()`;
  # `public` when it names none), which in production is not on the
  # connection's search path. It is one of the two names runtime.exs allows, so
  # the statement for each is written here.
  @still_held """
  UPDATE SCHEMA.forum_reports
  SET escrow_status = 'credited'
  WHERE escrow_status = 'refund_failed'
  """
  @still_held_public String.replace(@still_held, "SCHEMA.", "public.")
  @still_held_patchbay_app String.replace(@still_held, "SCHEMA.", "patchbay_app.")

  def up do
    %{num_rows: held} = repo().query!(still_held(prefix() || "public"))
    IO.puts("forum_reports: #{held} refused refund(s) written back as held")
  end

  def down, do: :ok

  defp still_held("public"), do: @still_held_public
  defp still_held("patchbay_app"), do: @still_held_patchbay_app
end
