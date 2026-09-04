defmodule PatchbayWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint PatchbayWeb.Endpoint

      use PatchbayWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import PatchbayWeb.ConnCase
    end
  end

  setup tags do
    Patchbay.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  def vary_accept?(conn) do
    conn
    |> Plug.Conn.get_resp_header("vary")
    |> Enum.join(",")
    |> String.downcase()
    |> String.contains?("accept")
  end

  def markdown_response?(conn) do
    [type] = Plug.Conn.get_resp_header(conn, "content-type")
    String.starts_with?(type, "text/markdown")
  end

  def plain_response?(conn) do
    [type] = Plug.Conn.get_resp_header(conn, "content-type")
    String.starts_with?(type, "text/plain")
  end
end
