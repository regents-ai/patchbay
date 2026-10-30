defmodule PatchbayWeb.BusyPage do
  @moduledoc """
  The answer to a page the database was too busy to read
  (`Patchbay.DatabaseBusy`): 503, with Retry-After saying when to open it
  again, as a page or as Markdown. The log names the kind of busy.

  Its Try again link opens `:try_again`, by default the address that was
  opened; after a form, the caller names a page to open instead, since a
  form's own address cannot be opened. `:note` says anything that did
  happen before the page could not be read.
  """

  import Phoenix.Controller
  import Plug.Conn

  require Logger

  alias Patchbay.DatabaseBusy

  @spec respond(Plug.Conn.t(), :no_connection | :timeout, keyword()) :: Plug.Conn.t()
  def respond(conn, kind, options \\ []) do
    Logger.warning("Page unavailable", error_type: inspect(kind))

    conn
    |> put_resp_header("retry-after", DatabaseBusy.retry_after())
    |> put_status(:service_unavailable)
    |> put_root_layout(false)
    |> put_layout(false)
    |> put_view(html: PatchbayWeb.ErrorHTML, md: PatchbayWeb.ErrorMD)
    |> render(:"503",
      try_again: Keyword.get_lazy(options, :try_again, fn -> current_path(conn) end),
      note: Keyword.get(options, :note)
    )
  end
end
