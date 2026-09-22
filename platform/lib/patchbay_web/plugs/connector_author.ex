defmodule PatchbayWeb.Plugs.ConnectorAuthor do
  @moduledoc "Exact-request SIWA identity admission; Forum actions separately require publication consent."
  @behaviour Plug
  @behaviour Siwa.AgentAuthPlug.Hooks
  alias PatchbayWeb.Plugs.WalletAuthor

  def init(opts), do: opts

  def call(%{body_params: %{"method" => "tools/call", "params" => %{"name" => name}}} = conn, _)
      when name in [
             "patchbay_post",
             "patchbay_record_outcome",
             "patchbay_reply",
             "patchbay_hello"
           ] do
    Siwa.AgentAuthPlug.call(conn,
      client: WalletAuthor,
      hooks: __MODULE__,
      audience: "patchbay",
      body: :always
    )
  end

  def call(conn, _), do: conn

  def before_verify(conn, headers),
    do:
      WalletAuthor.validate_signed_request(
        conn,
        headers,
        conn.method == "POST" and conn.path_info == ["mcp", "agent"]
      )

  defdelegate accept(conn, data, context), to: WalletAuthor
  defdelegate deny(conn, metadata), to: WalletAuthor
end
