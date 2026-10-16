defmodule PatchbayWeb.Plugs.Parsers.LastRead do
  @moduledoc """
  One of Plug's own parsers (`:json`, `:urlencoded`, `:multipart`), whose
  refusals carry the request its last body read returned, as ash-template's
  parsers do, so a body over its limit or one that does not decode is answered
  413 or 400 in the request's own format rather than as a server error.
  `Plug.Parsers` raises both without the request, so each read is noted
  for this parse and forgotten once it ends. The multipart parser reads its
  parts itself, so its refusal of a body over its limit notes the request it
  returned.
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

    {reader, opts} =
      Keyword.pop(Keyword.merge(opts, own), :body_reader, {Plug.Conn, :read_body, []})

    module = Module.concat(Plug.Parsers, name |> Atom.to_string() |> String.upcase())
    {module, module.init([body_reader: {__MODULE__, :read_body, [reader]}] ++ opts)}
  end

  @impl Plug.Parsers
  def parse(conn, type, subtype, params, {module, opts}) do
    case module.parse(conn, type, subtype, params, opts) do
      {:error, :too_large, read} ->
        Process.put(__MODULE__, read)
        raise Plug.Parsers.RequestTooLargeError

      result ->
        result
    end
  rescue
    error ->
      Plug.Conn.WrapperError.reraise(Process.get(__MODULE__, conn), :error, error, __STACKTRACE__)
  after
    Process.delete(__MODULE__)
  end

  @doc false
  def read_body(conn, opts, {module, function, args}) do
    result = apply(module, function, [conn, opts | args])
    with {_read, _body, %Plug.Conn{} = read} <- result, do: Process.put(__MODULE__, read)
    result
  end
end
