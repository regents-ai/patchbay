defmodule Patchbay.Points do
  @moduledoc "This site's part in Regent Points: what it offers Points, as it happens."

  use Ash.Domain

  resources do
    resource(Patchbay.Points.Award)
  end
end
