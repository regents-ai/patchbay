defmodule PatchbayWeb.WalletBodyReader do
  @moduledoc "Captures bounded, exact wallet request bytes while retaining shared profile limits."

  def read_body(%{path_info: path} = conn, opts)
      when path in [["hello"], ["api", "agent", "hello"]],
      do: capture(conn, opts, 16_384)

  def read_body(%{path_info: ["api", "agent" | _]} = conn, opts), do: capture(conn, opts, 100_000)

  # A shared agent pairing request (`regent_agents`), signed over its exact bytes.
  def read_body(%{path_info: ["api", "agents", "v1" | _]} = conn, opts),
    do: capture(conn, opts, 16_384)

  def read_body(conn, opts), do: RegentIdentity.BodyReader.read_body(conn, opts)

  defp capture(conn, opts, limit) do
    opts = opts |> Keyword.put(:length, limit) |> Keyword.put(:read_length, limit + 1)

    case Plug.Conn.read_body(conn, opts) do
      {status, chunk, conn} when status in [:ok, :more] ->
        body = Map.get(conn.assigns, :raw_body, "") <> chunk
        if byte_size(body) > limit, do: raise(Plug.Parsers.RequestTooLargeError)

        conn =
          conn
          |> Plug.Conn.assign(:raw_body, body)
          |> Plug.Conn.put_private(:wallet_body_complete, status == :ok)

        {status, chunk, conn}

      other ->
        other
    end
  end
end
