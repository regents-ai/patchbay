defmodule PatchbayWeb.OffersRedirectController do
  use PatchbayWeb, :controller

  def list(conn, params) do
    query = Map.take(params, ["q"])
    redirect(conn, to: ~p"/offers?#{query}")
  end

  def history(conn, _params), do: redirect(conn, to: ~p"/offers/history")
end
