defmodule PatchbayWeb.WalletBodyReader do
  @moduledoc """
  Captures bounded, exact request bytes where a signature covers them: wallet
  requests, and the events Stripe signs. Every other request keeps the shared
  profile limits.
  """

  def read_body(%{path_info: path} = conn, opts)
      when path in [["hello"], ["api", "agent", "hello"]],
      do: keep(conn, opts, 16_384)

  def read_body(%{path_info: ["api", "agent" | _]} = conn, opts), do: keep(conn, opts, 100_000)

  def read_body(%{path_info: ["webhooks", "stripe"]} = conn, opts), do: keep(conn, opts, 262_144)

  def read_body(conn, opts), do: RegentIdentity.BodyReader.read_body(conn, opts)

  defp keep(conn, opts, limit) do
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
