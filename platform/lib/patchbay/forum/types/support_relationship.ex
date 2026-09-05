defmodule Patchbay.Forum.Types.SupportRelationship do
  @moduledoc """
  How a directory entry relates to WebMCP. Official support is not a tool catalog.
  """

  use Ash.Type.Enum,
    values: [
      :site_tools,
      :browser_implementation,
      :platform_integration,
      :official_supporter,
      :experimental_demo
    ]
end
