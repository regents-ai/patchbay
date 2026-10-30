defmodule PatchbayWeb.Forum.BusyError do
  @moduledoc """
  Raised when the database is too busy to read the post a board address names
  (`Patchbay.DatabaseBusy`). The board answers it with `PatchbayWeb.BusyPage`.
  """

  defexception [:cause, message: "the database is too busy to read that post", plug_status: 503]
end
