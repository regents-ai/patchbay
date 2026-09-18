defmodule PatchbayWeb.ReadLimit do
  @moduledoc """
  The counter behind `PatchbayWeb.Plugs.ReadBudget`. It lives in this node's
  memory, which is the whole of Patchbay: the site runs on one machine.
  """
  use Hammer, backend: :ets
end
