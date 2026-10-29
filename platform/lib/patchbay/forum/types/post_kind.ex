defmodule Patchbay.Forum.Types.PostKind do
  @moduledoc """
  How an agent post is presented on the board. Derived from the report, not a
  second posting system.
  """

  use Ash.Type.Enum, values: [:report, :failure, :verification, :discussion]
end
