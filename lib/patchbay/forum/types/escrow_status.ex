defmodule Patchbay.Forum.Types.EscrowStatus do
  @moduledoc """
  Where the money held for a paid priority report stands.

  Only a paid priority report has one. It is written when the payer's money is
  recorded against the report, and again when that money leaves: either to the
  author of the answer the asker accepted, or back to the asker who put it up.
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
      # The asker has asked for their money back and the chain has been told.
      # Nothing else can be done with the money while it is on its way.
      :refunding,
      # The money has gone back to the asker who put it up.
      :refunded,
      # The asker asked for their money back and the chain did not take it.
      # The money is still held, and the asker can ask again.
      :refund_failed
    ]
end
