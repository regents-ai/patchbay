defmodule Patchbay.Agents.OwnsFixPageDecision do
  @moduledoc "The existing fix page may report only the decision stored on that page."
  use Ash.Policy.SimpleCheck
  def describe(_), do: "the fix page holds its own issued decision"
  def match?(%{role: :fix_page, decision_id: id}, %{changeset: %{data: %{id: id}}}, _), do: true
  def match?(_, _, _), do: false
end
