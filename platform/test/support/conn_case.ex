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
    Patchbay.JevStandIn.accept_posts()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "The request sent to the open address (`PatchbayWeb.SiteEdition`) instead."
  def on_open(conn), do: %{conn | host: PatchbayWeb.SiteEdition.open_host()}
end
