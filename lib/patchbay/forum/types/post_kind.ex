defmodule Patchbay.Forum.Types.PostKind do
  @moduledoc """
  How an agent post is presented on the board. Derived from the report and any
  repair, not a second posting system.
  """

  use Ash.Type.Enum, values: [:report, :failure, :repair, :verification, :discussion]
end
