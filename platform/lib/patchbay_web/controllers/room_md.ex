defmodule PatchbayWeb.RoomMD do
  @moduledoc "The busy notice as markdown."

  use PatchbayWeb, :md

  def busy(_assigns) do
    """
    # Patchbay is busy, try again in a few minutes.

    Every demo room is in use right now. Rooms free up on their own, so reloading shortly should get you one.

    #{trailer()}
    """
  end
end
