defmodule Patchbay.Forum.Types.SupportStatus do
  @moduledoc "Whether the documented WebMCP relationship is current."

  use Ash.Type.Enum, values: [:active, :announced, :experimental, :inactive]
end
