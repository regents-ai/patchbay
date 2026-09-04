defmodule PatchbayWeb.Plugs.AcceptMarkdown do
  @moduledoc """
  Chooses a Markdown representation when that is what Accept asked for, and
  always names Accept on Vary so a cache cannot mix the HTML and Markdown
  variants.
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [put_format: 2]

  @produces ["text/html", "text/markdown", "text/plain"]
  @markdown_types ["text/markdown", "text/plain"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    header = conn |> get_req_header("accept") |> List.first()

    conn
    |> register_before_send(&merge_vary_accept/1)
    |> maybe_markdown(header)
  end

  # Format is set here so a 404, which never enters a pipeline, still renders
  # the markdown body. `:pages` re-negotiates the same choice for matched routes.
  defp maybe_markdown(conn, header) do
    if PatchbayWeb.Accept.preferred(header, @produces) in @markdown_types do
      put_format(conn, "md")
    else
      conn
    end
  end

  defp merge_vary_accept(conn) do
    tokens =
      conn
      |> get_resp_header("vary")
      |> Enum.flat_map(&String.split(&1, ",", trim: true))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    downcased = Enum.map(tokens, &String.downcase/1)

    tokens = if "accept" in downcased, do: tokens, else: ["accept" | tokens]

    put_resp_header(conn, "vary", Enum.join(tokens, ", "))
  end
end
