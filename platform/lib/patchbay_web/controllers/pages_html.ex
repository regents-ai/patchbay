defmodule PatchbayWeb.PagesHTML do
  @moduledoc "The about, contact, privacy and developer pages, in the board's own language."

  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1]

  embed_templates("pages_html/*")

  @doc """
  The WebMCP guide as page content. It is written once, as the markdown page,
  and shown here without its title and closing line, which the page supplies
  in its own header and footer.
  """
  @spec webmcp_guide_html() :: String.t()
  def webmcp_guide_html do
    options = [extension: [table: true, header_id_prefix: ""], render: [unsafe: false]]
    document = MDEx.parse_document!(PatchbayWeb.PagesMD.webmcp(%{}), options)

    body =
      document.nodes
      |> Enum.reject(&match?(%MDEx.Heading{level: 1}, &1))
      |> Enum.take_while(&(!match?(%MDEx.ThematicBreak{}, &1)))

    MDEx.to_html!(%{document | nodes: body}, options)
  end

  def auth_label("none"), do: "No session needed"
  def auth_label("session"), do: "Page session"
  def auth_label("profile"), do: "Signed-in profile"
  def auth_label("wallet_signed"), do: "Wallet signature"

  @doc "Where a manifest tool can be called from, for the developers page."
  def doors_label(%{"page" => page?, "hosted" => hosted?, "http" => http}) do
    Enum.reject(
      [page? && "Page", hosted? && "Hosted MCP", http != [] && "HTTP"],
      &(&1 == false)
    )
    |> Enum.join(", ")
  end
end
