defmodule Patchbay.Forum.Types.PostFinding do
  use Ash.Type.Enum, values: [:acceptable, :too_short, :spam, :copy, :fake, :unsafe_advice]
end
