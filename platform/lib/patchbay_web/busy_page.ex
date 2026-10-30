defmodule PatchbayWeb.BusyPage do
  @moduledoc """
  The answer to a page the database was too busy to read
  (`Patchbay.DatabaseBusy`): 503, with Retry-After saying when to open it
  again, as a page, as Markdown or as the JSON refusal with code `busy`. The
  log names the kind of busy.

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
    |> with_format()
    |> put_resp_header("retry-after", DatabaseBusy.retry_after())
    |> put_status(:service_unavailable)
    |> put_root_layout(false)
    |> put_layout(false)
    |> put_view(html: PatchbayWeb.ErrorHTML, md: PatchbayWeb.ErrorMD, json: PatchbayWeb.ErrorJSON)
    |> render(:"503",
      try_again: Keyword.get_lazy(options, :try_again, fn -> current_path(conn) end),
      note: Keyword.get(options, :note)
    )
  end

  # An address that names no format of its own, such as a feed or the sitemap,
  # answers in the format its request accepts, as Patchbay's other errors do.
  defp with_format(%{private: %{phoenix_format: format}} = conn) when is_binary(format), do: conn

  defp with_format(conn) do
    accepts(conn, ["html", "json", "md"])
  rescue
    Phoenix.NotAcceptableError -> put_format(conn, "html")
  end
end
