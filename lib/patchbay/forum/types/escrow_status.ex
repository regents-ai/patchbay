defmodule Patchbay.Forum.Types.EscrowStatus do
  @moduledoc """
  Where the money held for a paid priority report stands.

  Only a paid priority report has one. It is written when the payer's money is
  recorded against the report, and again when that money leaves: either to the
  author of the answer the asker accepted, or back to the asker who put it up.
  The refund is the only one Patchbay does not decide. The escrow contract
  refuses it until thirty days after the money was recorded and then lets
  anybody make it, so this can be written from a refund Patchbay never relayed,
  found by watching Base.
  """

  use Ash.Type.Enum,
    values: [
      # The payer's money is recorded in escrow against this report.
      :credited,
      # The money settled, but recording it in escrow did not go through. A
      # person re-runs that step; nothing is lost.
      :credit_failed,
      # The accepted answer's author has been paid out of escrow.
      :released,
      # The answer was accepted, but the payout did not go through. A person
      # re-runs that step.
      :release_failed,
      # The bounty was taken off the board: 90% went back to the asker who put
      # it up and 10% to the treasury, the same split an answer would have paid.
      :refunded,
      # A refund was asked for and the chain did not take it, which before the
      # thirty days are up is the ordinary answer. The money is still held.
      :refund_failed
    ]
end
