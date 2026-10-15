defmodule PatchbayWeb.Plugs.Parsers.TooLarge do
  @moduledoc """
  One of Plug's own parsers (`:json`, `:urlencoded`, `:multipart`), whose
  refusal of a body over its limit carries the request the parser returned.
  `Plug.Parsers` raises that refusal without it, and Bandit answers only on the
  request its latest read returned, so the 413 otherwise became a server error.
  """

  @behaviour Plug.Parsers

  @impl Plug.Parsers
  def init(opts) do
    {parser, opts} = Keyword.pop!(opts, :parser)

    {name, own} =
      case parser do
        {name, own} -> {name, own}
        name -> {name, []}
      end

    module = Module.concat(Plug.Parsers, name |> Atom.to_string() |> String.upcase())
    {module, module.init(Keyword.merge(opts, own))}
  end

  @impl Plug.Parsers
  def parse(conn, type, subtype, params, {module, opts}) do
    case module.parse(conn, type, subtype, params, opts) do
      {:error, :too_large, conn} ->
        {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)
        Plug.Conn.WrapperError.reraise(conn, :error, %Plug.Parsers.RequestTooLargeError{}, stack)

      result ->
        result
    end
  end
end
