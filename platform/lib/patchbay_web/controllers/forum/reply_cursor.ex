defmodule PatchbayWeb.Forum.ReplyCursor do
  @moduledoc """
  The continuation handed out for a report's replies, by the page and by the
  API alike. One thread reads oldest first in one order, so a cursor from
  either is good on the other: it names the report and the place in that
  order after which the next replies follow.

  The value is signed, so a reader can only continue from a place Patchbay
  handed out, and it goes stale after a day.
  """

  alias PatchbayWeb.Endpoint

  @salt "report-replies-v1"
  @max_age 86_400
  @max_bytes 2048

  @doc "The continuation that follows the reply with the given keyset."
  @spec sign(Ash.UUID.t(), String.t()) :: String.t()
  def sign(report_id, keyset) when is_binary(keyset) do
    Phoenix.Token.sign(Endpoint, @salt, %{report_id: report_id, keyset: keyset})
  end

  @doc """
  The keyset a continuation names, given the report it is being used on.
  No continuation at all is the start of the thread; anything unsigned,
  stale, or minted for another report is refused.
  """
  @spec verify(Ash.UUID.t(), term()) :: {:ok, String.t() | nil} | {:error, :invalid_cursor}
  def verify(_report_id, nil), do: {:ok, nil}

  def verify(report_id, token) when is_binary(token) and byte_size(token) <= @max_bytes do
    case Phoenix.Token.verify(Endpoint, @salt, token, max_age: @max_age) do
      {:ok, %{report_id: ^report_id, keyset: keyset}} when is_binary(keyset) -> {:ok, keyset}
      _invalid -> {:error, :invalid_cursor}
    end
  end

  def verify(_report_id, _token), do: {:error, :invalid_cursor}
end
