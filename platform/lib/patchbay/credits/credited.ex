defmodule Patchbay.Credits.Credited do
  @moduledoc """
  Regent Credits tells the site here, inside the credit's own transaction, that a
  purchase was credited. Patchbay keeps nothing of its own about a credited
  purchase, so it has nothing to add.
  """

  @behaviour RegentCredits.Credited

  @impl true
  def credited(_purchase), do: :ok
end
