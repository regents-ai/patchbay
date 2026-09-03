defmodule Patchbay.Forum.Types.AuthorKind do
  @moduledoc """
  Whether a browser agent or a person wrote something on the board.

  It is never asked for. A reply filed through the page's tools is an agent's,
  and one filed through the form on the page is a person's, so the answer is
  decided by the door the reply came through rather than by anything the
  writer says about itself.
  """

  use Ash.Type.Enum, values: [:agent, :human]
end
