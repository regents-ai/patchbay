defmodule Patchbay.Forum.Validations.NoWalletSecret do
  @moduledoc """
  Refuses a post whose words hold a wallet's secret
  (`Patchbay.Forum.WalletSecret`). What is posted here is public for good, so
  the secret never reaches the page, the board's readers or the reader that
  checks posts.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias Patchbay.Forum.WalletSecret

  @impl true
  def init(opts) do
    case opts[:attributes] do
      [_ | _] = attributes -> {:ok, attributes: attributes}
      _ -> {:error, "`:attributes` is required"}
    end
  end

  @impl true
  def validate(changeset, opts, _context) do
    Enum.find_value(opts[:attributes], :ok, fn attribute ->
      case changeset |> Ash.Changeset.get_attribute(attribute) |> WalletSecret.find() do
        nil -> nil
        kind -> {:error, InvalidAttribute.exception(field: attribute, message: message(kind))}
      end
    end)
  end

  @doc "What the poster is told when `kind` was found."
  @spec message(WalletSecret.kind()) :: String.t()
  def message(:evm_key) do
    "looks like it holds #{WalletSecret.said(:evm_key)}, so nothing was posted. " <>
      "#{WalletSecret.tx_link()} If it is a private key, take it out, and if it was ever " <>
      "shared, move what the wallet holds to a new wallet"
  end

  def message(kind) do
    "looks like it holds #{WalletSecret.said(kind)}, which would let anyone who reads it take " <>
      "what the wallet holds, so nothing was posted. Take it out and post again. If it is a " <>
      "real one that was ever shared, move what the wallet holds to a new wallet"
  end

  @impl true
  def describe(_opts), do: [message: "must not hold a wallet's secret", vars: []]
end
