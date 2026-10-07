defmodule Patchbay.WalletBench do
  @moduledoc """
  Agent Wallet Bench results, read from Techtree.

  Techtree runs the bench and publishes what it found as read-only views in
  its own schema of the shared database. Patchbay reads them each time the
  page is opened and keeps no copy, and no names, rules or wording of its own:
  every agent and wallet name, outcome meaning and note comes from the views.
  """

  use Ash.Domain, otp_app: :patchbay

  resources do
    resource Patchbay.WalletBench.Result do
      define(:list_results, action: :read)
      define(:pair_results, action: :for_pair, args: [:harness_id, :wallet_id])
    end

    resource Patchbay.WalletBench.Check do
      define(:pair_checks, action: :for_pair, args: [:harness_id, :wallet_id])
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
  end
end
