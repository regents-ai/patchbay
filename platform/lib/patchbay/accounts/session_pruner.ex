defmodule Patchbay.Accounts.SessionPruner do
  @moduledoc """
  Deletes, once a day, the sign-in session rows no browser can still hold
  (`Patchbay.Accounts.SessionAuthority.prune/0`). Every browser that starts a
  sign-in gets a row, and revoked and lapsed rows stay behind, so without this
  the table only grows.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Patchbay.Accounts.SessionAuthority

  @impl Oban.Worker
  def perform(_job), do: SessionAuthority.prune()
end
