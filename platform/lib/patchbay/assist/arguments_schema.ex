defmodule Patchbay.Assist.ArgumentsSchema do
  @moduledoc """
  The shape the drafting model is held to when it writes a tool call's
  arguments: one JSON object, carried as a string, and nothing else.
  """

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
