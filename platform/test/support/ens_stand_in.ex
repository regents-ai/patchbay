defmodule PatchbayWeb.EnsStandIn do
  @moduledoc """
  Stands in for `AgentEns.PrimaryName` in tests
  (`config :patchbay, Patchbay.Accounts.EnsIdentity, :primary_name`), so no
  test reads Ethereum. A wallet's lookup answers what the test said with
  `answer/2`; a wallet the test said nothing about has no name.
  """

  @doc "What the lookup of `wallet` answers for the rest of the calling test."
  @spec answer(String.t(), {:ok, map() | nil} | {:error, term()}) :: :ok
  def answer(wallet, answer) do
    answers = Application.get_env(:patchbay, __MODULE__, %{})
    Application.put_env(:patchbay, __MODULE__, Map.put(answers, wallet, answer))
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:patchbay, __MODULE__) end)
  end

  @spec verified_primary_identity(String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def verified_primary_identity(wallet, _opts),
    do: Map.get(Application.get_env(:patchbay, __MODULE__, %{}), wallet, {:ok, nil})
end
