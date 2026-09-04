defmodule PatchbayWeb.Layouts do
  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [site_nav: 1]

  embed_templates "layouts/*"

  def canonical(%Plug.Conn{request_path: "/"}), do: PatchbayWeb.Documents.origin()
  def canonical(%Plug.Conn{request_path: path}), do: PatchbayWeb.Documents.origin() <> path

  def og_image, do: PatchbayWeb.Documents.absolute("/apple-touch-icon.png")

  attr :data, :map, required: true
  attr :nonce, :string, default: nil

  def json_ld(assigns) do
    json = Jason.encode!(assigns.data, escape: :html_safe)

    nonce_attr =
      case assigns.nonce do
        nonce when is_binary(nonce) and nonce != "" -> ~s( nonce="#{nonce}")
        _missing -> ""
      end

    # Script bodies are not interpolated by HEEx, so the tag is built as HTML.
    tag = {:safe, ~s(<script type="application/ld+json"#{nonce_attr}>#{json}</script>)}
    assigns = assign(assigns, :tag, tag)

    ~H"""
    {@tag}
    """
  end
end
