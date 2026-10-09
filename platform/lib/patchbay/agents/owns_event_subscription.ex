defmodule Patchbay.Agents.OwnsEventSubscription do
  @moduledoc false
  use Ash.Policy.SimpleCheck
  def describe(_), do: "owns this event subscription"

  def match?(%Patchbay.Agents.Actor{} = actor, %{changeset: changeset}, _) do
    Ash.Changeset.get_attribute(changeset, :owner_id) in actor.principals
  end

  def match?(_, _, _), do: false
end
