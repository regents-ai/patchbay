defmodule Patchbay.Patchbay.OpenAI.CandidateSchema do
  @moduledoc false

  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["improved_skill_markdown", "change_summary", "warnings"],
      "properties" => %{
        "improved_skill_markdown" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => 65_536
        },
        "change_summary" => %{
          "type" => "array",
          "maxItems" => 6,
          "items" => %{"type" => "string", "maxLength" => 240}
        },
        "warnings" => %{
          "type" => "array",
          "maxItems" => 4,
          "items" => %{"type" => "string", "maxLength" => 240}
        }
      }
    }
  end
end
