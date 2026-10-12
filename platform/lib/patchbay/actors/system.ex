defmodule Patchbay.Actors.System do
  @moduledoc "Patchbay itself, for the shared account reads and writes only the server makes."
  defstruct role: :system
end
