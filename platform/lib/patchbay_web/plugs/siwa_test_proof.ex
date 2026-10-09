defmodule PatchbayWeb.Plugs.SiwaTestProof do
  @moduledoc """
  SIWA verification for `GET /siwa-test`, the read-only check an agent runs to
  prove its sign-in works. It creates no profile and records nothing. A
  refusal from the sign-in service passes on its code, message and hint; a
  request refused here before it is checked says what to change.
  """
  @behaviour Plug
  @behaviour Siwa.AgentAuthPlug.Hooks
  import Plug.Conn
  alias PatchbayWeb.ApiError
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
  def before_verify(conn, _headers) do
    permitted? =
      conn.method == "GET" and conn.path_info == ["siwa-test"] and
        conn.body_params in [%{}, %Plug.Conn.Unfetched{aspect: :body_params}]

    WalletAuthor.validate_signed_request(conn, permitted?)
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
    if Regex.match?(~r/\A0x[0-9a-f]{40}\z/, address),
      do: {:ok, assign(conn, :siwa_wallet, address)},
      else: {:error, %{reason: :unsupported_principal, source: :siwa_test}}
  end

  def accept(_conn, _data, _context),
    do: {:error, %{reason: :unsupported_principal, source: :siwa_test}}

  @impl Siwa.AgentAuthPlug.Hooks
  def deny(conn, %{reason: :not_configured}) do
    refuse(
      conn,
      503,
      ApiError.body(
        "not_configured",
        "Agent sign-in is not set up on this Patchbay.",
        "This copy of Patchbay has no SIWA server set; run the test against https://patchbay.help/siwa-test."
      )
    )
  end

  def deny(conn, failure) do
    WalletAuthor.refuse_signed(
      conn,
      failure,
      "Your SIWA sign-in did not check out, so nothing was proved.",
      "Sign this exact request as https://siwa.regents.sh/skill.md shows: GET /siwa-test with no body and no query, for the audience patchbay."
    )
  end

  defp refuse(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
