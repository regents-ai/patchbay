defmodule Patchbay.Agents.AttributeAction do
  @moduledoc "Freeze the acting agent, beneficiary and episode when the product effect is committed."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: %Patchbay.Agents.Actor{} = actor}) do
    changeset =
      if changeset.action.name in [:ask_question, :post_reply, :file_report, :add_reply] and
           is_nil(Ash.Changeset.get_attribute(changeset, :client_request_id)),
         do:
           Ash.Changeset.add_error(changeset,
             field: :client_request_id,
             message: "is required for agent posts"
           ),
         else: changeset

    Enum.reduce(
      [:acting_agent_id, :beneficiary_profile_id, :human_account_id, :pairing_id],
      changeset,
      fn field, changeset ->
        Ash.Changeset.force_change_attribute(changeset, field, Map.fetch!(actor, field))
      end
    )
  end

  # A human correction to an upserted follow or use is attributed to that
  # human, rather than retaining the previous agent's episode.
  def change(%{action: %{name: name}} = changeset, _opts, _context)
      when name in [:subscribe, :record] do
    Enum.reduce(
      [:acting_agent_id, :beneficiary_profile_id, :human_account_id, :pairing_id],
      changeset,
      &Ash.Changeset.force_change_attribute(&2, &1, nil)
    )
  end

  def change(changeset, _opts, _context), do: changeset
end
