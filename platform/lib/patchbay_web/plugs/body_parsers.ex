defmodule PatchbayWeb.Plugs.BodyParsers do
  @moduledoc """
  `Plug.Parsers` whose refusals keep the connection they happened on.

  Phoenix renders an error with the connection the endpoint started from, so
  a body that cannot be read would otherwise be refused in whatever `Accept`
  asks for. Re-raising through `Plug.Conn.WrapperError` hands Phoenix the
  connection after `RegentAgentAccess.Plug` ran, so a malformed body under an API
  prefix is refused as JSON like every other error there.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: Plug.Parsers.init(opts)

  @impl Plug
  def call(conn, opts) do
    Plug.Parsers.call(conn, opts)
  rescue
    error -> Plug.Conn.WrapperError.reraise(conn, :error, error, __STACKTRACE__)
  end
end
