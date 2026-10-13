defmodule PatchbayWeb.Plugs.X402Test do
  @moduledoc """
  The charge on the Wallet Bench's paid-call test page: one x402 payment of
  0.01 USDC on Base, from the caller's wallet straight to the Bench's own
  funder wallet, which pays for the Bench's runs and so gets its cent back.
  Patchbay holds no key for that wallet and keeps no record of the payment;
  it is not revenue, and earns no Credits or Points.

  The price, the chain, the token and the path are fixed here, and nothing in
  a request changes them. The wallet paid is the site's `:x402_test_pay_to`
  setting, read when this module is built and refused then unless it is one
  whole, correctly written address.

  `X402.Plug.PaymentGate` does the work: an unpaid request is answered 402
  with the terms; a payment that is malformed, pays another wallet or another
  amount, or has run out of time is refused here without asking the payment
  service; the rest are verified by that service, and the page's answer is
  sent only once the service has settled the payment. A payment that fails
  to settle gets the 402 instead. A payment sent a second time is refused
  here too, from the library's own record of the ones it has seen
  (`replays/0`, started with the site).
  """

  @behaviour Plug

  alias RegentPayments.USDC
  alias X402.Extensions.PaymentIdentifier.ETSCache
  alias X402.Plug.PaymentGate

  @path "/bench/x402-test"
  # 0.01 USDC, in the token's smallest unit.
  @price "10000"

  @configured Application.compile_env!(:patchbay, :x402_test_pay_to)
  @pay_to (case RegentChain.Address.decode(@configured) do
             {:ok, _address} ->
               @configured

             :error ->
               raise ArgumentError,
                     "config :patchbay, :x402_test_pay_to is not one correctly written address"
           end)

  @doc "The record of payments already seen, as the site's supervisor starts it."
  @spec replays() :: Supervisor.child_spec()
  def replays, do: Supervisor.child_spec({ETSCache, name: __MODULE__}, id: __MODULE__)

  @impl Plug
  def init(_opts) do
    PaymentGate.init(
      facilitator: RegentPayments.Facilitator,
      local_verification: :structural,
      payment_identifier_cache: __MODULE__,
      claim_order: :before_verify,
      routes: [
        %{
          method: :get,
          path: @path,
          price: @price,
          network: USDC.network(),
          asset: USDC.asset(),
          pay_to: @pay_to,
          extra: USDC.signing_domain(),
          description: "Wallet Bench paid-call test"
        }
      ]
    )
  end

  @impl Plug
  def call(conn, opts), do: PaymentGate.call(conn, opts)
end
