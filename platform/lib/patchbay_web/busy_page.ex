defmodule PatchbayWeb.BusyPage do
  @moduledoc """
  The answer to a page the database was too busy to read
  (`Patchbay.DatabaseBusy`): 503, with Retry-After saying when to open it
  again, as a page or as Markdown. The log names the kind of busy.
  """

  import Phoenix.Controller
  import Plug.Conn

  require Logger

  alias Patchbay.DatabaseBusy

  @spec respond(Plug.Conn.t(), :no_connection | :timeout) :: Plug.Conn.t()
  def respond(conn, kind) do
    Logger.warning("Page unavailable", error_type: inspect(kind))

    conn
    |> put_resp_header("retry-after", DatabaseBusy.retry_after())
    |> put_status(:service_unavailable)
    |> put_root_layout(false)
    |> put_layout(false)
    |> put_view(html: PatchbayWeb.ErrorHTML, md: PatchbayWeb.ErrorMD)
    |> render(:"503")
  end
end
