defmodule PatchbayWeb.WalletBodyReader do
  @moduledoc "Captures bounded, exact wallet request bytes while retaining shared profile limits."

  def read_body(%{path_info: ["api", "agent" | _]} = conn, opts) do
    opts = opts |> Keyword.put(:length, 100_000) |> Keyword.put(:read_length, 100_001)

    case Plug.Conn.read_body(conn, opts) do
      {status, chunk, conn} when status in [:ok, :more] ->
        body = Map.get(conn.assigns, :raw_body, "") <> chunk
        if byte_size(body) > 100_000, do: raise(Plug.Parsers.RequestTooLargeError)

        conn =
          conn
          |> Plug.Conn.assign(:raw_body, body)
          |> Plug.Conn.put_private(:wallet_body_complete, status == :ok)

        {status, chunk, conn}

      other ->
        other
    end
  end

  def read_body(conn, opts), do: RegentIdentity.BodyReader.read_body(conn, opts)
end
