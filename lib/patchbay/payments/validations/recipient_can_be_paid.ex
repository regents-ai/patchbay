defmodule Patchbay.Payments.Validations.RecipientCanBePaid do
  @moduledoc """
  Refuses a tip nobody could receive: a profile that is not active, a profile
  with no wallet of its own, or the payer paying themselves.

  The check belongs here rather than in the endpoint because the wallet it
  reads is the one about to be frozen into the terms. A tip offered to a
  profile that cannot hold USDC would be a payment with nowhere to land.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidArgument

  @wallet_address ~r/\A0x[0-9a-f]{40}\z/

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :recipient) do
      %{} = recipient -> payable(changeset, recipient)
      _absent -> :ok
    end
  end

  @impl true
  def describe(_opts) do
    [message: "cannot be paid", vars: []]
  end

  @spec payable(Ash.Changeset.t(), struct()) :: :ok | {:error, Exception.t()}
  defp payable(changeset, recipient) do
    cond do
      recipient.status != :active ->
        refuse("is not taking payments right now")

      not is_binary(recipient.wallet_address) or
          not Regex.match?(@wallet_address, recipient.wallet_address) ->
        refuse("has no wallet to be paid at")

      recipient.id == Ash.Changeset.get_attribute(changeset, :actor_profile_id) ->
        refuse("cannot be yourself")

      true ->
        :ok
    end
  end

  @spec refuse(String.t()) :: {:error, Exception.t()}
  defp refuse(message) do
    {:error, InvalidArgument.exception(field: :recipient, message: message)}
  end
end
