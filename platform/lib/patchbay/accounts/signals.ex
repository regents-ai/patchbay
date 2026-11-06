defmodule Patchbay.Accounts.Signals do
  @moduledoc """
  What accounts tell the rest of the site, as Ash signals. Each is emitted in
  the sign-in's own transaction, so a listener with the default delivery
  commits or rolls back with it. Points offers it to Regent Points
  (`Patchbay.Points.Award`). As ash-template's `AshTemplate.Accounts.Signals`.

    * `:account_registered`: a sign-in created the person's shared Regent
      account. A later sign-in to the same account emits nothing.
  """

  use Ash.Signals

  signals do
    signal :account_registered do
      argument(:account_id, :integer, allow_nil?: false)
    end
  end
end
