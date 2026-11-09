defmodule Patchbay.Accounts.EnsIdentity.LookUp do
  @moduledoc """
  Reads the ENS name and picture of the account's current wallet before the
  row is written.

  The account's wallet is read when the job runs, not when the lookup was
  asked for, and the chain is read before the update and outside any
  transaction. A name is kept only when it resolves back to the same wallet,
  and a picture only when the ENS avatar service answers with one
  (`AgentEns.PrimaryName`). The row is then written with the wallet it was
  read for. An account with no wallet is written as done, with no name and no
  picture.

  A failed read fails the action as a server fault, so the job retries with
  backoff and the reason reaches saved errors (`Patchbay.SavedErrors` leaves
  out invalid input); a server with no Ethereum endpoint cancels it. The
  avatar service not answering in time is a failed read too, never "no
  picture": it is slow for a name it has not been asked about lately, and the
  picture already stored must outlast that.

  The answer is written only while the row is as the job read it. A sign-in
  while the read runs asks again and moves the row on, so the write fails as
  stale and AshOban cancels the job; the `:look_up` trigger's sweep then
  queues a new one, which reads the account's wallet afresh.
  """

  use Ash.Resource.Change

  require Ash.Expr

  alias Ash.Error.Unknown.UnknownError
  alias AshOban.Errors.CancelJob
  alias Patchbay.Accounts.EnsIdentity

  @impl true
  def change(changeset, _opts, _context) do
    read_at = changeset.data.updated_at

    changeset
    |> Ash.Changeset.filter(Ash.Expr.expr(updated_at == ^read_at))
    |> Ash.Changeset.before_action(fn changeset ->
      # Patchbay's own job: the account is read to learn its wallet, for nobody's request.
      account = Ash.load!(changeset.data, :human_account, authorize?: false).human_account

      case look_up(account.wallet_address) do
        {:ok, identity} ->
          changeset
          |> keep_wallet(account.wallet_address)
          |> Ash.Changeset.force_change_attribute(:ens_name, identity[:name])
          |> Ash.Changeset.force_change_attribute(:ens_avatar_url, identity[:avatar_url])
          |> Ash.Changeset.force_change_attribute(:lookup_state, :done)

        {:cancel, reason} ->
          Ash.Changeset.add_error(changeset, CancelJob.exception(reason: reason))

        {:error, reason} ->
          Ash.Changeset.add_error(
            changeset,
            UnknownError.exception(error: "ENS lookup failed: #{inspect(reason)}")
          )
      end
    end)
  end

  defp keep_wallet(changeset, nil), do: changeset

  defp keep_wallet(changeset, wallet),
    do: Ash.Changeset.force_change_attribute(changeset, :wallet_address, wallet)

  defp look_up(nil), do: {:ok, %{}}

  defp look_up(wallet) do
    case EnsIdentity.rpc_url() do
      nil ->
        {:cancel, :no_ethereum_endpoint}

      rpc_url ->
        with {:ok, identity} <-
               EnsIdentity.primary_name().verified_primary_identity(wallet, rpc_url: rpc_url),
             do: {:ok, identity || %{}}
    end
  end
end
