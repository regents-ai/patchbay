defmodule PatchbayWeb.Plugs.ReadBudget do
  @moduledoc """
  Gives each address a share of reads a minute, so one caller cannot keep the
  database busy for everyone else.

  A read is a `GET` or `HEAD` that reaches the router, or any message to the
  hosted MCP tools (a hosted write also draws on its session's hourly share),
  or a fix asked for from the home page, which counts free fixes and draws
  the page again when it is refused. Files served ahead of the router and
  the health check are not counted. Other posts are left alone: each has
  its own hourly share, and nothing here stands between a person and a
  payment.

  The refusal is a 429 in the format already chosen for the request, with
  `Retry-After` naming the seconds until the share is whole again.
  """

  @behaviour Plug

  import Plug.Conn

  alias PatchbayWeb.ClientAddress
  alias PatchbayWeb.ReadLimit

  @default_reads_per_minute 120
  @window :timer.minutes(1)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if counted?(conn) do
      case ReadLimit.hit(ClientAddress.address(conn), @window, reads_per_minute()) do
        {:allow, _count} -> conn
        {:deny, wait} -> refuse(conn, wait)
      end
    else
      conn
    end
  end

  # Matched on the path's segments, as the router matches, so a spelling the
  # router accepts (`/mcp/`, `//mcp`) is counted the same as the plain one.
  defp counted?(%Plug.Conn{path_info: ["webmcp", "health"]}), do: false
  defp counted?(%Plug.Conn{method: method}) when method in ["GET", "HEAD"], do: true
  defp counted?(%Plug.Conn{method: "POST", path_info: ["mcp"]}), do: true
  defp counted?(%Plug.Conn{method: "POST", path_info: ["fixes"]}), do: true
  defp counted?(_conn), do: false

  defp refuse(conn, wait) do
    {content_type, body} = body(conn.private[:phoenix_format])

    conn
    |> put_resp_header("retry-after", wait |> div(1000) |> max(1) |> Integer.to_string())
    |> put_resp_content_type(content_type)
    |> send_resp(:too_many_requests, body)
    |> halt()
  end

  defp body("json"),
    do: {"application/json", Jason.encode!(PatchbayWeb.ErrorJSON.render("429.json", %{}))}

  defp body("md"), do: {"text/markdown", PatchbayWeb.ErrorMD.render("429.md", %{})}

  defp body(_html),
    do: {"text/plain", "Too many reads from this address. Wait a minute, then try again.\n"}

  defp reads_per_minute do
    Application.get_env(:patchbay, :reads_per_minute, @default_reads_per_minute)
  end
end
