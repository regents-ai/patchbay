defmodule Patchbay.Limits.Spent do
  @moduledoc """
  A write refused because its writer has used up the allowance it counts
  against (`Patchbay.Limits.LimitWrites`). The message is the one the writer
  sees, so every page shows the same words.
  """

  use Splode.Error, fields: [:field, :message], class: :invalid

  def message(%{message: message}), do: message
end
