defmodule PatchbayWeb.Plugs.ReadBudget do
  @moduledoc """
  Gives each address a share of reads a minute, so one caller cannot keep the
  database busy for everyone else.

  A read is a `GET` or `HEAD` that reaches the router, or any message to the
  hosted MCP tools (a hosted post also draws on the hourly share of the
  signed agent's owner's account), an agent pairing with a person's
  Regent account, or a page's report of what only the browser saw
  (`PatchbayWeb.VisitLogController`). Files served ahead of the router and the health check are
  not counted. Other posts are left alone: each has its own hourly share, a
  signed agent's requests have their own share by the minute
  (`PatchbayWeb.Plugs.SignedBudget`), and nothing here stands between a
  person and a payment.

  Every counted answer carries the standard `RateLimit-Policy` and
  `RateLimit` headers for the "reads" share. The refusal is a 429 in the
  format already chosen for the request, with `Retry-After` naming the
  seconds until the share is whole again. At the two hosted MCP addresses it
  is a JSON-RPC answer to the request instead, with the same headers and the
  seconds in the body (`PatchbayWeb.MCP.Refusal`).
  """

  @behaviour Plug

  import Plug.Conn

  alias PatchbayWeb.ClientAddress
  alias PatchbayWeb.RateLimitHeaders
  alias PatchbayWeb.ReadLimit

  @default_reads_per_minute 120
  @window :timer.minutes(1)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if counted?(conn) do
      quota = reads_per_minute()
      {address, _source} = ClientAddress.key(conn)

      case ReadLimit.hit(address, @window, quota) do
        {:allow, count} -> RateLimitHeaders.add(conn, "reads", quota, @window, quota - count)
        {:deny, wait} -> conn |> RateLimitHeaders.add("reads", quota, @window, 0) |> refuse(wait)
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
  defp counted?(%Plug.Conn{method: "POST", path_info: ["chatgpt", "mcp"]}), do: true
  defp counted?(%Plug.Conn{method: "POST", path_info: ["api", "agents", "v1", "pair"]}), do: true
  defp counted?(%Plug.Conn{method: "POST", path_info: ["visit-log"]}), do: true
  defp counted?(_conn), do: false

  defp refuse(%Plug.Conn{method: "POST", path_info: path} = conn, wait)
       when path in [["mcp"], ["chatgpt", "mcp"]],
       do: PatchbayWeb.MCP.Refusal.rate_limited(conn, RateLimitHeaders.seconds(wait))

  # The type and body are the fixed refusals in `body/2`; nothing from the request
  # reaches them but the theme the visitor chose, which `PatchbayWeb.Plugs.Theme` checks.
  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  defp refuse(conn, wait) do
    {content_type, body} = body(conn.private[:phoenix_format], conn)

    conn
    |> put_resp_header("retry-after", wait |> RateLimitHeaders.seconds() |> Integer.to_string())
    |> put_resp_content_type(content_type)
    |> send_resp(:too_many_requests, body)
    |> halt()
  end

  defp body("json", _conn),
    do: {"application/json", Jason.encode!(PatchbayWeb.ErrorJSON.render("429.json", %{}))}

  defp body("md", _conn), do: {"text/markdown", PatchbayWeb.ErrorMD.render("429.md", %{})}

  defp body(_html, conn),
    do:
      {"text/html",
       Phoenix.Template.render_to_iodata(PatchbayWeb.ErrorHTML, "429", "html", %{conn: conn})}

  defp reads_per_minute do
    Application.get_env(:patchbay, :reads_per_minute, @default_reads_per_minute)
  end
end
