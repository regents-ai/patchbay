defmodule Patchbay.Payments.JevAssist do
  @moduledoc """
  A paid assist: one fixed fee, paid into the wallet Patchbay takes its fee
  at, for Patchbay to work out the right tool call on another site.

  The terms freeze the request exactly as the agent wrote it, the wallet the
  fee goes to, how much, and the id the run will be opened under. Once the
  money settles, the run is opened from those terms and nothing else, in the
  same transaction that marks the payment applied, so a request changed after
  the fact cannot be what Patchbay works on. A run that could not open (the
  payer already has one under way, say) is opened on the payer's next call,
  and one payment can never open two.

  Work on the run starts once that transaction has committed (`start/1`).
  """

  @behaviour RegentPayments.Offer

  alias Ash.Error.Changes.InvalidArgument
  alias Ash.Error.Changes.InvalidChanges
  alias Patchbay.Assist
  alias Patchbay.Assist.Request
  alias RegentPayments.USDC

  # A paid assist costs one fixed fee, named here and nowhere the caller can
  # reach.
  @fee_atomic 100_000

  @not_set_up "Paid assists are not set up on this Patchbay."

  @impl true
  def kind, do: :jev_assist

  @impl true
  def target_type, do: :assist_run

  @impl true
  def payer?(_actor), do: true

  @doc "What a paid assist costs, in USDC's atomic units."
  @spec fee_atomic() :: pos_integer()
  def fee_atomic, do: @fee_atomic

  @doc "Freezes a paid assist of `request`, as `Patchbay.Assist.Request.draft/1` returned it."
  @impl true
  def freeze(%{request: request}, actor) do
    with :ok <- drafted(request),
         {:ok, pay_to_address} <- pay_to_address() do
      # The run does not exist yet, so its id is minted here and frozen with
      # the rest.
      run_id = Ash.UUID.generate()

      {:ok,
       %{
         amount_atomic: @fee_atomic,
         pay_to_address: pay_to_address,
         target_id: run_id,
         payload: author_origin(%{"run_id" => run_id, "request" => request}, actor),
         recipient_snapshot: [
           %{"wallet_address" => pay_to_address, "amount_atomic" => @fee_atomic}
         ],
         effect_summary:
           "Ask Patchbay to work out the right tool call on #{Request.host(request)} " <>
             "for #{USDC.format(@fee_atomic)} USDC"
       }}
    end
  end

  @doc """
  Opens the run a settled intent paid for, from its frozen terms. The payer
  is the actor; a run paid for on a page belongs to the browser `context`
  names as well.
  """
  @impl true
  def carry_out(intent, _receipt, actor, context) do
    case Assist.open_run(%{intent: intent, browser_session_id: context.browser_session_id},
           actor: actor
         ) do
      {:ok, _run} -> {:ok, :complete}
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def resumes?, do: true

  @doc """
  Starts work on the run an applied intent opened, while it is still waiting
  for it. Safe to call on every read of the intent: a run already under way,
  or answered, is left alone, and a second start of a waiting run is refused
  by the run itself.
  """
  @spec start(RegentPayments.PaymentIntent.t()) :: :ok
  def start(intent) do
    # Patchbay's own look-up of the run the payer's intent names.
    case Assist.get_run(intent.target_id, authorize?: false) do
      {:ok, %{status: :paid} = run} -> Assist.Runner.start(run)
      _started_or_gone -> :ok
    end
  end

  # The request is held to its own rules here as well as at the door, so
  # nothing reaches frozen terms that the door would have refused.
  defp drafted(request) do
    case Request.draft(request) do
      {:ok, ^request} ->
        :ok

      _refused ->
        {:error,
         InvalidArgument.exception(
           field: :request,
           message: "must be an assist request in the fields such a request takes"
         )}
    end
  end

  defp pay_to_address do
    case Assist.pay_to_address() do
      nil -> {:error, InvalidChanges.exception(message: @not_set_up)}
      address -> {:ok, address}
    end
  end

  # A wallet author pays and reads its assist back through the wallet-signed
  # endpoints, and the terms say so.
  defp author_origin(payload, %{authentication_origin: :wallet}),
    do: Map.put(payload, "author_origin", "wallet")

  defp author_origin(payload, _actor), do: payload
end
