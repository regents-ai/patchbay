defmodule Patchbay.Patchbay.Changes.SetContractDigest do
  use Ash.Resource.Change

  alias Patchbay.Patchbay.Digest

  @impl true
  def change(changeset, _opts, _context) do
    contract = %{
      name: Ash.Changeset.get_attribute(changeset, :name),
      title: Ash.Changeset.get_attribute(changeset, :title),
      description: Ash.Changeset.get_attribute(changeset, :description),
      input_schema: Ash.Changeset.get_attribute(changeset, :input_schema),
      annotations: Ash.Changeset.get_attribute(changeset, :annotations),
      handler_adapter: Ash.Changeset.get_attribute(changeset, :handler_adapter),
      output_contract: Ash.Changeset.get_attribute(changeset, :output_contract),
      postcondition_set: Ash.Changeset.get_attribute(changeset, :postcondition_set)
    }

    Ash.Changeset.change_attribute(changeset, :contract_sha256, Digest.contract_sha256(contract))
  end
end
