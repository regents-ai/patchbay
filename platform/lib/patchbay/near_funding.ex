defmodule Patchbay.NearFunding do
  @moduledoc """
  Fund with NEAR: a person tops up one of their paired agents' own Base USDC
  wallets by sending NEAR from their own NEAR wallet, swapped by the NEAR
  Intents 1Click service (`RegentNearIntents`).

  Patchbay only quotes and reads progress. The USDC always lands at the
  agent's own wallet, the one that signs its x402 payments, as Patchbay's own
  record of the agent names it; nobody types it. Any refund goes back to the
  NEAR account the person names. The agent then pays as it always does.

  Off unless `PATCHBAY_NEAR_FUNDING_ENABLED` is `"true"` (`enabled?/0`).
  """

  use Ash.Domain, otp_app: :patchbay

  alias Patchbay.NearFunding.Funding
  alias RegentPayments.USDC

  resources do
    resource Funding do
      define(:get_funding, action: :read, get_by: [:id])

      define(:latest_funding,
        action: :latest,
        args: [:privy_user_id],
        get?: true,
        not_found_error?: false
      )

      define(:refresh_funding, action: :refresh)
      define(:record_funding_status, action: :record_status)
    end
  end

  @doc "Whether Fund with NEAR is switched on."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:patchbay, :near_funding_enabled?, false)

  @doc """
  Starts a funding for `agent`, one of the signed-in person's own paired
  agents as `RegentAgents` returned it: a live quote and its deposit address.
  From `params` only the USDC amount (`"amount_usdc"`, such as `"5.00"`) and
  the NEAR refund account (`"refund_to"`) are read; the recipient is always
  the agent's own wallet.
  """
  @spec start(map(), map()) :: {:ok, Funding.t()} | {:error, Ash.Error.t()}
  def start(%{id: pairing_id, wallet: wallet, privy_user_id: privy_user_id}, params) do
    Funding
    |> Ash.Changeset.for_create(:start, %{
      pairing_id: pairing_id,
      privy_user_id: privy_user_id,
      recipient: wallet,
      refund_to: params["refund_to"],
      usdc_amount: usdc_amount(params["amount_usdc"])
    })
    |> Ash.create()
  end

  defp usdc_amount(amount) do
    case USDC.parse(amount) do
      {:ok, atomic} -> atomic
      :error -> nil
    end
  end
end
