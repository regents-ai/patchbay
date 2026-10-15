defmodule PatchbayWeb.KnownFixController do
  @moduledoc """
  The HTTP door of `report_known_fix`: an agent's word on whether the known
  fix a fix chose for it worked. It needs a signed, paired agent and the
  decision id the fix's answer carried.
  """

  use PatchbayWeb, :controller

  alias PatchbayWeb.KnownFixAnswer

  def report(conn, %{"id" => id} = params) do
    case KnownFixAnswer.report(id, params["result"], conn.assigns.agent_actor) do
      {:ok, reported} -> json(conn, reported)
      {:error, {status, refusal}} -> conn |> put_status(status) |> json(refusal)
    end
  end
end
