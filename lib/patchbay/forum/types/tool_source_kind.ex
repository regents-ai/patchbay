defmodule Patchbay.Forum.Types.ToolSourceKind do
  @moduledoc "Where a tool row was learned from."

  use Ash.Type.Enum, values: [:official, :observed, :agent_reported]
end
