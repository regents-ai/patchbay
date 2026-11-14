defmodule PatchbayWeb.CursorAge do
  @moduledoc """
  A cursor Patchbay handed out, signed again as if it had been handed out a
  month ago, so a test can read on from it a month later without waiting a
  month.
  """

  @month 30 * 86_400

  @doc "The same cursor, signed under its own `salt` as it would have been a month ago."
  @spec aged(String.t(), String.t()) :: String.t()
  def aged(cursor, salt) do
    {:ok, data} = Phoenix.Token.verify(PatchbayWeb.Endpoint, salt, cursor, max_age: :infinity)

    Phoenix.Token.sign(PatchbayWeb.Endpoint, salt, data,
      signed_at: System.system_time(:second) - @month
    )
  end
end
