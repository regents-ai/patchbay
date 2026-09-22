defmodule Patchbay.Assist do
  @moduledoc """
  Paid assists: an agent that is stuck on a site's tools pays a fixed fee and
  tells Patchbay what it is trying to do, and Patchbay works out the right
  call for it.

  The fee is paid through Patchbay Rewards like every other paid action, to
  the one wallet this Patchbay is set up to take it at. Without that wallet,
  assists answer that they are not set up here and nothing else changes.
  """

  use Ash.Domain, otp_app: :patchbay

  require Ash.Query

  alias Patchbay.Assist.Run
  alias Patchbay.Assist.Runner

  resources do
    resource Patchbay.Assist.Run do
      define(:open_run, action: :open)
      define(:get_run, action: :read, get_by: [:id])

      define(:get_open_run_for_payer,
        action: :open_run_for_payer,
        args: [:payer_profile_id],
        get?: true,
        not_found_error?: false
      )

      define(:start_run, action: :start)
      define(:record_step, action: :record_step, args: [:step])
      define(:finish_run, action: :finish)
      define(:record_deposit, action: :record_deposit)
      define(:reopen_run, action: :reopen)
    end
  end

  @doc """
  Marks every open run as failed. Called once at boot: the work those runs
  were doing, or waiting for, died with the last process, and a call to a
  site is never made twice on a guess.
  """
  @spec interrupt_open_runs() :: :ok
  def interrupt_open_runs do
    # Patchbay's own boot-time sweep: it answers to nobody's request.
    Patchbay.Assist.Run
    |> Ash.Query.for_read(:open_runs)
    |> Ash.bulk_update!(:interrupt, %{}, authorize?: false, return_records?: false)

    :ok
  end

  @doc """
  Marks one run as failed if it is still open: its worker died or ran past
  its time, and a person looks at it. A run already answered is left as it is.
  """
  @spec interrupt_run(Ash.UUID.t()) :: :ok
  def interrupt_run(run_id) do
    # Patchbay's own runner closing a run whose worker it lost.
    Patchbay.Assist.Run
    |> Ash.Query.for_read(:open_runs)
    |> Ash.Query.filter(id == ^run_id)
    |> Ash.bulk_update!(:interrupt, %{}, authorize?: false, return_records?: false)

    :ok
  end

  @doc """
  Hands a run that waited on a person back to Patchbay: the run is reopened
  as paid, the fact is written on it, and the runner picks it up like any
  other. Nothing is paid twice, and a fee already forwarded is not forwarded
  again. A run that is not waiting on a person is left as it is. Run by a
  person at Patchbay from the release's console:

      bin/patchbay rpc 'Patchbay.Assist.rerun("<run id>")'
  """
  @spec rerun(Ash.UUID.t()) :: {:ok, Run.t()} | {:error, term()}
  def rerun(run_id) do
    # A person at Patchbay's console: the run answers to no request.
    with {:ok, run} <- get_run(run_id, authorize?: false),
         {:ok, reopened} <- reopen_run(run, authorize?: false),
         {:ok, noted} <-
           record_step(reopened, %{"note" => "A person at Patchbay picked this up again."},
             authorize?: false
           ) do
      Runner.start(noted)
      {:ok, noted}
    end
  end

  @doc """
  The wallet a paid assist's fee is paid to, or nil when this Patchbay has
  none set.
  """
  @spec pay_to_address() :: String.t() | nil
  def pay_to_address, do: setting(:pay_to_address)

  @doc """
  The REGENT staking contract each fee is forwarded to as revenue, or nil
  when this Patchbay has none set, in which case fees stay in the wallet
  they were paid to.
  """
  @spec staking_contract_address() :: String.t() | nil
  def staking_contract_address, do: setting(:staking_contract_address)

  defp setting(name) do
    case Application.get_env(:patchbay, :assist, [])[name] do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _unset ->
        nil
    end
  end
end
