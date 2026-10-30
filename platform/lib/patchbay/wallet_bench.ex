defmodule Patchbay.WalletBench do
  @moduledoc """
  Agent Wallet Bench results, read from Techtree.

  Techtree runs the bench and publishes what it found as read-only views in
  its own schema of the shared database. Patchbay reads them in full once a
  minute and shares that reading with every visitor of the board and of How
  the bench works and of each pair's page (`Patchbay.WalletBench.Board`).
  Patchbay keeps no names, rules or wording of its
  own: every agent and wallet name, outcome meaning and note comes from the
  views.
  """

  use Ash.Domain, otp_app: :patchbay

  resources do
    resource Patchbay.WalletBench.Result do
      define(:list_results, action: :read)
    end

    resource Patchbay.WalletBench.SetSummary do
      define(:list_sets, action: :read)
    end

    resource Patchbay.WalletBench.Check do
      define(:list_checks, action: :read)
    end

    resource Patchbay.WalletBench.Fixed do
      define(:list_fixed, action: :read)
    end

    resource Patchbay.WalletBench.RosterEntry do
      define(:list_roster, action: :read)
    end

    resource Patchbay.WalletBench.Note do
      define(:list_notes, action: :read)
    end

    resource Patchbay.WalletBench.ExtraNote do
      define(:list_extra_notes, action: :read)
    end
  end
end
