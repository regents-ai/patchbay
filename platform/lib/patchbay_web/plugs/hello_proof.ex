defmodule PatchbayWeb.Plugs.HelloProof do
  @moduledoc "SIWA verification for greetings, without creating profiles or touching payments."
  @behaviour Plug
  @behaviour Siwa.AgentAuthPlug.Hooks
  import Plug.Conn
  alias PatchbayWeb.Plugs.WalletAuthor

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    Siwa.AgentAuthPlug.call(conn,
      client: WalletAuthor,
      hooks: __MODULE__,
      audience: "patchbay",
      body: :if_present
    )
  end

  @impl Siwa.AgentAuthPlug.Hooks
  def before_verify(conn, headers) do
    permitted? =
      conn.method == "POST" and conn.path_info == ["api", "agent", "hello"] and
        is_map(conn.body_params) and Map.keys(conn.body_params) -- ["name", "language"] == []

    WalletAuthor.validate_signed_request(conn, headers, permitted?)
  end

  @impl Siwa.AgentAuthPlug.Hooks
  def accept(
        conn,
        %{
          "verified" => true,
          "walletAddress" => address,
          "chainId" => 8453,
          "principal" => %{
            "kind" => "wallet",
            "wallet_address" => address,
            "chain_id" => 8453,
            "audience" => "patchbay"
          }
        },
        _context
      )
      when is_binary(address) do
    if Regex.match?(~r/\A0x[0-9a-f]{40}\z/, address) do
      {:ok, assign(conn, :hello_wallet, address)}
    else
      {:error, %{reason: :unsupported_principal, source: :hello}}
    end
  end

  def accept(_conn, _data, _context),
    do: {:error, %{reason: :unsupported_principal, source: :hello}}

  @impl Siwa.AgentAuthPlug.Hooks
  def deny(conn, failure), do: WalletAuthor.deny(conn, failure)
end
