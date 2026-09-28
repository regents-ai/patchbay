defmodule PatchbayDev.PaymentsLab do
  @moduledoc """
  The payments lab: a page's tip paid for real on a copy of Base on this
  machine, through the same page code and the same payment door a person's
  browser uses. Two things stand in for the real ones: the wallet app (the
  page's stand-in, `dev/assets/payments_lab.ts`, after the template's
  `onchain_lab.ts`) and the payment service (`PatchbayDev.LabFacilitator`).

  Start the copy of Base, then the site with the stand-in payment service:

      anvil --port 58611 --fork-url "$REGENT_BASE_RPC_URL" --prune-history --no-storage-caching
      X402_FACILITATOR_URL=http://127.0.0.1:$PORT/dev/lab/payments/facilitator mix phx.server

  Anvil's accounts carry code on Base (someone delegated them), which makes
  USDC check their signatures as a contract's; clear it on the copy for A, B,
  C, D and the payment service's relayer:

      for a in 0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266 \\
               0x70997970c51812dc3a010c7d01b50e0d17dc79c8 \\
               0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc \\
               0x90f79bf6eb2c4f870365e785982e1f101e93b906 \\
               0xa0ee7a142d267c1f36714e4a8f75612f20a79720; do
        cast rpc --rpc-url http://127.0.0.1:58611 anvil_setCode $a 0x
      done

  Give wallet A some USDC by writing its balance into USDC's balances, the
  mapping at storage slot 9 (`anvil_dealERC20` cannot find it):

      cast rpc --rpc-url http://127.0.0.1:58611 anvil_setStorageAt \\
        0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \\
        "$(cast index address 0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266 9)" \\
        0x00000000000000000000000000000000000000000000000000000000004c4b40

  then open /dev/lab/payments. The lab account signs in with wallet A, anvil's
  first account; B and C are other wallets. Tips go to D. Stop anvil afterwards and
  delete its folder under ~/.foundry/anvil/tmp; a copy of Base keeps growing.
  """
  use PatchbayWeb, :controller

  alias Patchbay.Identity
  alias Patchbay.Payments.USDC
  alias PatchbayWeb.PaymentsAPI.WalletPayment
  alias PatchbayWeb.Plugs.CurrentProfile

  @wallets [
    {"A", "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"},
    {"B", "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"},
    {"C", "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc"}
  ]
  @signed_in "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
  @recipient {"D", "0x90f79bf6eb2c4f870365e785982e1f101e93b906"}

  def show(conn, _params) do
    signed_in = conn.assigns[:current_profile]

    html(conn, """
    <!DOCTYPE html>
    <html lang="en">
    <head><meta charset="utf-8"><title>Payments lab</title>
    <meta name="csrf-token" content="#{get_csrf_token()}"></head>
    <body style="font: 15px/1.5 system-ui; max-width: 46rem; margin: 2rem auto; padding: 0 1rem">
    <h1>Payments lab</h1>
    <p>A tip paid on a copy of Base on this machine, through Patchbay's own page code.</p>

    <h2>Account</h2>
    <p id="lab-account">#{account(signed_in)}</p>
    <form method="post" action="/dev/lab/payments/sign-in">
      <input type="hidden" name="_csrf_token" value="#{get_csrf_token()}">
      <button>Sign in as the lab account</button>
    </form>

    <h2>USDC</h2>
    <ul id="lab-balances">#{balances()}</ul>

    <section id="lab-wallet">
      <h2>Wallet app</h2>
      <fieldset><legend>Open wallet</legend>
      #{wallet_choices()}
      <label><input type="radio" name="lab-wallet" value="" checked> None</label>
      </fieldset>
      <fieldset><legend>Wallet network</legend>
      <label><input type="radio" name="lab-network" value="8453" checked> Base (the copy)</label>
      <label><input type="radio" name="lab-network" value="1"> Ethereum</label>
      </fieldset>
      <label><input type="checkbox" name="lab-refuse-switch"> Refuse to switch network</label>
      <label><input type="checkbox" name="lab-decline"> Decline in the wallet</label>
      <label><input type="checkbox" name="lab-slow"> Answer slowly (1.5 s a request)</label>
      <label><input type="checkbox" name="lab-low-v"> End signatures with 0 or 1, not 27 or 28</label>
      <p data-lab-log aria-live="polite"></p>
    </section>

    <h2>Tip D</h2>
    <form id="lab-tip" data-recipient="#{get_session(conn, "payments_lab_recipient")}">
      <label>USDC <input name="amount" value="0.10" size="8"></label>
      <button id="lab-tip-button">Tip</button>
    </form>
    <ol id="lab-results"></ol>
    <script type="module" src="/assets/js/payments_lab.js"></script>
    </body></html>
    """)
  end

  def sign_in(conn, _params) do
    {_name, recipient} = @recipient

    payer =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:payments-lab",
        wallet_address: @signed_in
      })

    tipped =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:payments-lab-recipient",
        wallet_address: recipient
      })

    conn
    |> put_session(CurrentProfile.session_key(), payer.id)
    |> put_session("payments_lab_recipient", tipped.public_id)
    |> redirect(to: "/dev/lab/payments")
  end

  @doc """
  What the stand-in wallet asks of the copy of Base: a typed-data signature
  from one of its own lab accounts, and nothing else.
  """
  def wallet(conn, %{"method" => "eth_signTypedData_v4", "params" => [from, typed_data]})
      when is_binary(from) and is_binary(typed_data) do
    reply =
      if String.downcase(from) in Enum.map(@wallets, &elem(&1, 1)) do
        case rpc("eth_signTypedData_v4", [from, typed_data]) do
          {:ok, signature} -> %{result: signature}
          {:error, error} -> %{error: error}
        end
      else
        %{error: %{code: 4100, message: "Not a lab wallet."}}
      end

    json(conn, reply)
  end

  @doc ~s(Asks the copy of Base, answering `{:ok, result}` or `{:error, %{"code", "message"}}`.)
  def rpc(method, params) do
    body = %{jsonrpc: "2.0", id: 1, method: method, params: params}

    case Req.post(lab_chain(), json: body, retry: false) do
      {:ok, %{body: %{"result" => result}}} ->
        {:ok, result}

      {:ok, %{body: %{"error" => error}}} ->
        {:error, error}

      {:error, _unreachable} ->
        {:error, %{"code" => -32_603, "message" => "The copy of Base is not running."}}
    end
  end

  defp lab_chain, do: Application.fetch_env!(:patchbay, :payments_lab).rpc_url

  defp account(nil), do: "Signed out."

  defp account(profile), do: "Signed in with #{name(WalletPayment.signed_in(profile))}."

  defp wallet_choices do
    Enum.map_join(@wallets, "\n", fn {name, address} ->
      on = if address == @signed_in, do: "signed in", else: "another wallet"

      ~s(<label><input type="radio" name="lab-wallet" value="#{address}"> ) <>
        "#{name} <code>#{RegentFormat.short_address(address)}</code> (#{on})</label>"
    end)
  end

  defp balances do
    Enum.map_join(@wallets ++ [@recipient], "\n", fn {name, address} ->
      "<li>#{name}: #{balance(address)}</li>"
    end)
  end

  defp balance(address) do
    call = %{to: USDC.asset(), data: RegentChain.Call.encode("balanceOf(address)", [address])}

    case rpc("eth_call", [call, "latest"]) do
      {:ok, "0x" <> hex} -> "#{USDC.format(String.to_integer(hex, 16))} USDC"
      {:error, %{"message" => message}} -> message
    end
  end

  defp name(address) do
    case Enum.find(@wallets, &(elem(&1, 1) == address)) do
      {name, _address} -> name
      nil -> RegentFormat.short_address(address)
    end
  end
end
