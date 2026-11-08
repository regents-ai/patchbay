defmodule Patchbay.Forum.Types.EscrowStatus do
  @moduledoc """
  Where the money held for a paid priority report stands.

  Only a paid priority report has one, and before its first value the report
  is paid but its money not yet handed over (nil). Each move is a named action
  of `Patchbay.Forum.Report` that names the states it may start from, so a late
  writer can never put one state over a later one:

      nil ──sent──▶ credit_submitted ──Base holds it──▶ credited
       │                    │                                │
    last try fails    receipt reverted              accepted, payout sent
       ▼                    ▼                                ▼
      credit_failed ◀───────┘                       release_submitted ──Base paid──▶ released
      (a person re-runs: back to nil)                        │
                                          reverted, or not in a block in an hour
                                                             ▼
                                                       release_failed
                                                (a person re-runs: back to credited)

  Every try to hand a payout over failing moves `credited` to
  `release_failed`. Base holding the money also moves `credit_failed` to
  `credited`, and Base paying out moves `release_failed` to `released`: a
  send written as failed that went through after all.

  Any state the money is still in escrow from becomes `refunded` when the
  contract says it went back: thirty days after the money was recorded anybody
  may refund it, so this can be written from a refund Patchbay never relayed,
  found by watching Base (`Patchbay.Escrow.Watch`). The database keeps only
  these values, and only on a report that carries a bounty.
  """

  use Ash.Type.Enum,
    values: [
      # The request to record the payer's money against this report has been
      # handed to Base and the chain has not confirmed it yet. Base is asked
      # until it has; a request its receipt says the contract refused is
      # written as failed.
      :credit_submitted,
      # The chain confirmed the payer's money is recorded in escrow against
      # this report.
      :credited,
      # The money settled, but recording it on Base did not go through after
      # every try. A person re-runs that step (`retry_escrow_credit`); the
      # watch writes it as credited if Base did record it after all.
      :credit_failed,
      # The asker accepted an answer and the payout to its author has been
      # handed to Base, which has not confirmed it yet.
      :release_submitted,
      # The contract says the accepted answer's author has been paid out of
      # escrow.
      :released,
      # The answer was accepted, but the payout did not go through. The money
      # is still held. A person re-runs that step (`retry_escrow_release`); the
      # watch writes it as released if Base did pay it after all.
      :release_failed,
      # The bounty was taken off the board: 90% went back to the asker who put
      # it up and 10% was kept for REGENT staking, the same split an answer
      # would have paid.
      :refunded
    ]
end
