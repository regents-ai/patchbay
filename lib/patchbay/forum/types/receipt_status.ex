defmodule Patchbay.Forum.Types.ReceiptStatus do
  @moduledoc """
  What became of the receipt a report was filed with.

  Only `:verified` means the report was matched to a call Patchbay itself ran
  and logged. Every other value is a reason it could not be, and the report is
  kept exactly as its author told it.
  """

  use Ash.Type.Enum,
    values: [
      # No receipt was sent.
      :missing,
      # The receipt names no call Patchbay ran.
      :unknown,
      # The call is real but the report describes a different tool, contract or site.
      :mismatched,
      # The call is real but was issued to a different browser than the one reporting.
      :wrong_identity,
      # The call is real but a report already quotes it.
      :spent,
      # The call is real but happened too long ago to stand behind.
      :stale,
      # The report matches a call Patchbay ran, and carries that call's own facts.
      :verified
    ]
end
