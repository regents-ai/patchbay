defmodule Patchbay.Identity.Privy do
  @moduledoc "Verified Privy evidence for Patchbay's existing payment-account boundary."

  @doc """
  Verify both proof roles before requiring the wallet used by Patchbay accounts,
  and record the person in the shared Regent account (`Patchbay.Accounts`).
  Every refusal is `{:error, {stage, reason}}`; an account that could not be
  saved is reduced to `{:account_evidence, :account_rejected}` without being
  inspected.
  """
  def verify_session_pair(pair) do
    with {:ok, %RegentPrivy.Session{wallet_address: address} = evidence} when is_binary(address) <-
           RegentPrivy.Session.verify(pair, Application.get_env(:patchbay, :privy, [])),
         {:ok, _account} <- Patchbay.Accounts.establish(evidence) do
      {:ok,
       %{
         privy_user_id: evidence.privy_user_id,
         wallet_address: address
       }}
    else
      {:ok, _} -> {:error, {:account_evidence, :missing_linked_wallet}}
      {:error, {_stage, _reason}} = refused -> refused
      {:error, _rejected} -> {:error, {:account_evidence, :account_rejected}}
    end
  end

  @doc "The configured public Privy application identifier."
  def app_id do
    case Application.get_env(:patchbay, :privy, [])[:app_id] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
