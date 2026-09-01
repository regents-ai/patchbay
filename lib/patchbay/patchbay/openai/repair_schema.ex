defmodule Patchbay.Patchbay.OpenAI.RepairSchema do
  @moduledoc false

  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => [
        "root_cause",
        "description_replacement",
        "handler_adapter",
        "output_contract_version",
        "postcondition_set",
        "risk_notes"
      ],
      "properties" => %{
        "root_cause" => %{"type" => "string", "minLength" => 1, "maxLength" => 1_000},
        "description_replacement" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => 1_000
        },
        "handler_adapter" => %{
          "type" => "string",
          "enum" => ["apply_candidate_to_editor"]
        },
        "output_contract_version" => %{
          "type" => "string",
          "enum" => ["skill_uplift_verified_v1"]
        },
        "postcondition_set" => %{
          "type" => "string",
          "enum" => ["skill_candidate_written_v1"]
        },
        "risk_notes" => %{
          "type" => "array",
          "maxItems" => 4,
          "items" => %{"type" => "string", "maxLength" => 240}
        }
      }
    }
  end
end
