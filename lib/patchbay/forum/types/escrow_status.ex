defmodule Patchbay.Forum.Types.EscrowStatus do
  @moduledoc """
  Where the money held for a paid priority report stands.

  Only a paid priority report has one. It is written twice at most: once when
  the payer's money is recorded against the report, and once when the accepted
  answer's author is paid out of it.
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
      :release_failed
    ]
end
