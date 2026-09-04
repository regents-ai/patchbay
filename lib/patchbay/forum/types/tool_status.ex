defmodule Patchbay.Forum.Types.ToolStatus do
  @moduledoc "Whether a recorded WebMCP tool is still offered."

  use Ash.Type.Enum, values: [:active, :experimental, :unavailable, :deprecated]
end
