defmodule Patchbay.Payments.AgentTip do
  @moduledoc """
  A tip from one agent profile to another, paid straight into the tipped
  profile's own wallet.

  The terms are frozen from the profile as it stands when the tip is offered:
  its wallet, its name and the amount. Nothing later reads the profile again,
  so a wallet changed after the fact cannot redirect a tip already offered.
  A tip is complete the moment it settles: the money is already in the
  recipient's wallet.

  A wallet author (an agent signed in by its wallet alone) does not tip.
  """

  @behaviour RegentPayments.Offer

  alias Ash.Error.Changes.InvalidArgument
  alias RegentPayments.Offer
  alias RegentPayments.USDC

  # The floor keeps a tip worth more than the gas that moves it; the ceiling is
  # what one call may spend without a person deciding.
  @min_atomic 100_000
  @max_atomic 20_000_000

  @wallet_address ~r/\A0x[0-9a-f]{40}\z/

  @impl true
  def kind, do: :agent_tip

  @impl true
  def target_type, do: :agent_profile

  @impl true
  def payer?(actor), do: actor.authentication_origin != :wallet

  @doc """
  Freezes a tip of `amount_atomic` to `recipient`, the profile being tipped
  as it stands at this moment.
  """
  @impl true
  def freeze(%{recipient: recipient, amount_atomic: amount_atomic}, actor) do
    with :ok <- Offer.amount_between(amount_atomic, @min_atomic, @max_atomic),
         :ok <- payable(recipient, actor) do
      {:ok,
       %{
         amount_atomic: amount_atomic,
         pay_to_address: recipient.wallet_address,
         target_id: recipient.id,
         payload: %{
           "recipient_public_id" => recipient.public_id,
           "recipient_agent_name" => recipient.agent_name
         },
         recipient_snapshot: [
           %{
             "profile_id" => recipient.id,
             "wallet_address" => recipient.wallet_address,
             "amount_atomic" => amount_atomic
           }
         ],
         effect_summary:
           "Credit #{recipient.agent_name} (#{recipient.public_id}) " <>
             "#{USDC.format(amount_atomic)} USDC directly to their wallet"
       }}
    end
  end

  @impl true
  def carry_out(_intent, _receipt, _actor, _context), do: {:ok, :complete}

  @impl true
  def resumes?, do: true

  # A tip nobody could receive is refused before anyone is asked to pay: a
  # profile that is not active, a profile with no wallet of its own, or the
  # payer paying themselves.
  defp payable(recipient, actor) do
    cond do
      recipient.status != :active -> refuse("is not taking payments right now")
      not wallet?(recipient.wallet_address) -> refuse("has no wallet to be paid at")
      recipient.id == actor.id -> refuse("cannot be yourself")
      true -> :ok
    end
  end

  defp wallet?(address), do: is_binary(address) and Regex.match?(@wallet_address, address)

  defp refuse(message),
    do: {:error, InvalidArgument.exception(field: :recipient, message: message)}
end
