defmodule PatchbayWeb.KnownFixController do
  @moduledoc """
  The HTTP doors of `find_known_fix` and `report_known_fix`: Jev's free
  look at the known fixes for a site, and an agent's word on whether the
  fix it was handed worked. Neither needs a session; a report needs only the
  decision id the answer carried.
  """

  use PatchbayWeb, :controller

  alias PatchbayWeb.ClientAddress
  alias PatchbayWeb.KnownFixAnswer

  def show(conn, params) do
    case KnownFixAnswer.look_up(params, ClientAddress.visitor_key(conn)) do
      {:ok, answer} -> json(conn, KnownFixAnswer.json(answer))
      {:error, refusal} -> conn |> put_status(:unprocessable_entity) |> json(refusal)
    end
  end

  def report(conn, %{"id" => id} = params) do
    case KnownFixAnswer.report(id, params["result"]) do
      {:ok, reported} -> json(conn, reported)
      {:error, {status, refusal}} -> conn |> put_status(status) |> json(refusal)
    end
  end
end
