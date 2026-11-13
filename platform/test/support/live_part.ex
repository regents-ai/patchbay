defmodule PatchbayWeb.LivePart do
  @moduledoc "The live parts a page draws, for tests that join them as the browser does."

  @doc "The session `page` drew its live part `view` with, to join it by (`live_isolated/3`)."
  @spec session(String.t(), module()) :: map()
  def session(page, view) do
    page
    |> LazyHTML.from_document()
    |> LazyHTML.query("[data-phx-session]")
    |> LazyHTML.attribute("data-phx-session")
    |> Enum.map(&Phoenix.LiveView.Static.verify_token(PatchbayWeb.Endpoint, &1))
    |> Enum.find_value(fn
      {:ok, %{view: ^view, session: session}} -> session
      _other -> nil
    end)
  end
end
