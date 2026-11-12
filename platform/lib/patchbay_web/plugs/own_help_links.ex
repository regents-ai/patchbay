defmodule PatchbayWeb.Plugs.OwnHelpLinks do
  @moduledoc """
  Pairing and check-in are the shared Regent library's (`RegentAgents.HTTP`),
  and its refusals link to the help at patchbay.help. The open address
  (`PatchbayWeb.SiteEdition`) has the same help at its own address
  (`/errors/:code`), so a refusal it sends links there.
  """

  @behaviour Plug

  alias PatchbayWeb.SiteEdition

  @help "https://patchbay.help/errors/"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{assigns: %{site_edition: :open}} = conn, _opts),
    do: Plug.Conn.register_before_send(conn, &own_links/1)

  def call(conn, _opts), do: conn

  defp own_links(conn) do
    body =
      conn.resp_body
      |> IO.iodata_to_binary()
      |> String.replace(@help, SiteEdition.url(:open) <> "/errors/")

    %{conn | resp_body: body}
  end
end
