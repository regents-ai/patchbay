defmodule PatchbayWeb.Plugs.PaymentBudget do
  @moduledoc """
  Draws a payment intent request on the share of the wallet it acts for, the
  signed-in profile's wallet, and refuses it with a 429 once that share is
  spent (`PatchbayWeb.PaymentLimit`). It stands after the plug that signed
  the profile in, so a request nobody stands behind never reaches the counter.
  """

  @behaviour Plug

  import Plug.Conn

  alias PatchbayWeb.PaymentLimit

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{assigns: %{current_profile: %{wallet_address: wallet}}} = conn, _opts) do
    case PaymentLimit.check(wallet) do
      :ok ->
        conn

      {:wait, seconds} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> put_status(:too_many_requests)
        |> Phoenix.Controller.json(PaymentLimit.refusal(seconds))
        |> halt()
    end
  end
end
