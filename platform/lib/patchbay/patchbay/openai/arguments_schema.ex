defmodule Patchbay.Patchbay.OpenAI.ArgumentsSchema do
  @moduledoc false

  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["arguments_json"],
      "properties" => %{
        "arguments_json" => %{
          "type" => "string",
          "description" => "One JSON object: the arguments, and nothing around it.",
          "maxLength" => 8_192
        }
      }
    }
  end
end
