defmodule Patchbay.Patchbay.Validations.CanaryResult do
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @required_checks [
    "adapter_allowlisted",
    "postcondition_allowlisted",
    "candidate_present",
    "source_unchanged",
    "candidate_digest_changed",
    "frontmatter_valid",
    "identity_preserved",
    "output_contract_valid",
    "ui_revision_advanced"
  ]

  @impl true
  def validate(changeset, _opts, _context) do
    result = Ash.Changeset.get_attribute(changeset, :canary_result) || %{}
    passed = Map.get(result, "passed", Map.get(result, :passed))
    checks = Map.get(result, "checks", Map.get(result, :checks))

    if passed == true and is_map(checks) and
         Enum.all?(
           @required_checks,
           &(Map.get(checks, &1) == true or Map.get(checks, key_atom(&1)) == true)
         ) do
      :ok
    else
      {:error,
       InvalidAttribute.exception(
         field: :canary_result,
         message: "canary cannot be marked passed unless every check passes"
       )}
    end
  rescue
    ArgumentError ->
      {:error,
       InvalidAttribute.exception(
         field: :canary_result,
         message: "canary result checks are invalid"
       )}
  end

  @impl true
  def describe(_opts), do: "canary cannot be marked passed unless every check passes"

  defp key_atom("adapter_allowlisted"), do: :adapter_allowlisted
  defp key_atom("postcondition_allowlisted"), do: :postcondition_allowlisted
  defp key_atom("candidate_present"), do: :candidate_present
  defp key_atom("source_unchanged"), do: :source_unchanged
  defp key_atom("candidate_digest_changed"), do: :candidate_digest_changed
  defp key_atom("frontmatter_valid"), do: :frontmatter_valid
  defp key_atom("identity_preserved"), do: :identity_preserved
  defp key_atom("output_contract_valid"), do: :output_contract_valid
  defp key_atom("ui_revision_advanced"), do: :ui_revision_advanced
end
