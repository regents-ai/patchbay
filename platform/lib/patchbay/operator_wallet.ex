defmodule Patchbay.OperatorWallet do
  @moduledoc """
  What the operator wallet's own sends leave waiting, for the chain numbers
  Sentinel reads (`PatchbayWeb.Telemetry`, the site poller).

  The operator wallet sends two things whose answer the site waits for and
  writes down: a paid priority report's escrow credit, `credit_submitted`
  until `Patchbay.Escrow.Watch` reads it confirmed, and an assist fee's
  deposit to REGENT staking, `forwarding` while its job waits for the chain
  (`Patchbay.Assist.Forward`). The escrow's payouts, refunds and revenue
  pushes are written down as soon as Base takes them, so the site keeps no
  unconfirmed state for them.

  Beside those ages are Patchbay's own two numbers: paid priority reports
  whose escrow credit the chain has not yet confirmed, and the USDC of
  assist fees the operator wallet still holds, waiting, being forwarded or
  failed for a person to look at.

  The operator wallet's requests to its node go through Ethers, from
  `Patchbay.Escrow` and the payments library's fee forward, the only two
  callers of Ethers here. `attach/0` counts each one that gets no answer in
  `health.chain_request_failures.total`, as `Patchbay.ChainClient` counts
  its own, under the scope `operator`.
  """

  require Ash.Query

  import Ecto.Query, only: [from: 2]

  alias Patchbay.Assist.Run
  alias Patchbay.Forum.Report

  @usdc_atomic 1_000_000

  # The escrow and the REGENT staking contract are on Base.
  @operator_chain_id 8453

  @doc """
  Each sending flow with when its oldest unconfirmed send was signed, or nil
  when nothing waits: an escrow credit from when it was taken to be handed to
  Base, or last handed to it, a fee's forward from when it was taken.
  """
  @spec unconfirmed_sends() :: [{String.t(), DateTime.t() | nil}]
  def unconfirmed_sends do
    # The site's own rows, read for its health numbers on no one's behalf.
    [
      {"escrow_credit",
       Report
       |> Ash.Query.filter(escrow_status == :credit_submitted)
       |> Ash.min!(:escrow_credit_sent_at, authorize?: false)},
      {"fee_forward",
       Run
       |> Ash.Query.filter(deposit_status == :forwarding)
       |> Ash.min!(:fee_taken_at, authorize?: false)}
    ]
  end

  @doc """
  Paid priority reports whose escrow credit the chain has not yet confirmed:
  nobody has handed the credit over, Base has not confirmed it, or Base
  would not take it. A report paid with Patchbay Credits, before every
  payment was USDC, was marked credited as it was filed, so none is left
  here.
  """
  @spec escrow_unrecorded() :: non_neg_integer()
  def escrow_unrecorded do
    # The site's own rows, read for its health numbers on no one's behalf.
    Report
    |> Ash.Query.filter(
      not is_nil(priority_amount_atomic) and
        (is_nil(escrow_status) or escrow_status in [:credit_submitted, :credit_failed])
    )
    |> Ash.count!(authorize?: false)
  end

  @doc "USDC of assist fees in the operator wallet not yet deposited to staking."
  @spec assist_fees_unforwarded_usdc() :: float()
  def assist_fees_unforwarded_usdc do
    # One sum over the join of the site's runs and the payments library's
    # intents. Ash's unrelated exists cannot carry it: its subquery takes the
    # intents' schema prefix and looks for the runs there.
    atomic =
      Patchbay.Repo.one(
        from(run in "assist_runs",
          join: intent in "payment_intents",
          prefix: "regent_payments",
          on: intent.id == run.payment_intent_id,
          where: run.deposit_status in ["pending", "forwarding", "failed"],
          select: type(coalesce(sum(intent.amount_atomic), 0), :integer)
        )
      )

    atomic / @usdc_atomic
  end

  @doc "Counts the operator wallet's chain requests that get no answer; attached once at start."
  def attach,
    do:
      :telemetry.attach(
        "patchbay-operator-chain-requests",
        [:finch, :request, :stop],
        &__MODULE__.handle_request/4,
        nil
      )

  @doc false
  def handle_request(_event, _measurements, %{name: Ethereumex.Finch} = metadata, nil) do
    case no_answer(metadata.result) do
      nil ->
        :ok

      class ->
        :telemetry.execute([:patchbay, :chain, :failure], %{count: 1}, %{
          method: method(metadata.request.body),
          class: class,
          chain_id: @operator_chain_id,
          scope: "operator"
        })
    end
  end

  def handle_request(_event, _measurements, _other_client, nil), do: :ok

  # The node answered, unless it sent no answer, an HTTP error or a JSON-RPC
  # error. A revert is the contract's own answer, as `Patchbay.Escrow` reads
  # it (a push the staking contract refuses), so it is not counted.
  defp no_answer({:ok, %Finch.Response{status: 200, body: body}}),
    do: if(rpc_error?(body), do: "rpc")

  defp no_answer({:ok, %Finch.Response{status: status}}), do: "http_#{status}"

  defp no_answer({:error, %{reason: reason}}) when reason in [:timeout, :connect_timeout],
    do: "timeout"

  defp no_answer({:error, _transport}), do: "transport"

  defp rpc_error?(body) do
    String.contains?(body, ~s("error")) and
      case Jason.decode(body) do
        {:ok, %{"error" => %{"code" => 3}}} -> false
        {:ok, %{"error" => %{"message" => message}}} -> not String.contains?(message, "revert")
        {:ok, %{"error" => _error}} -> true
        _result -> false
      end
  end

  # Ethereumex sends one JSON-RPC call, or a batch of them.
  # Never raises: a handler that raises is detached for good, and the
  # operator wallet's failures would stop being counted until the next boot.
  defp method(body) when is_binary(body) or is_list(body) do
    case body |> IO.iodata_to_binary() |> Jason.decode() do
      {:ok, %{"method" => method}} when is_binary(method) -> method
      {:ok, [_ | _]} -> "batch"
      _unreadable -> "unreadable"
    end
  end

  defp method(_no_body), do: "unreadable"
end
