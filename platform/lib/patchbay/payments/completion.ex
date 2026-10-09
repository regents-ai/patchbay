defmodule Patchbay.Payments.Completion do
  @moduledoc "A completion identity may create only its exact, already settled paid effect."
  use Ash.Resource.Validation

  alias RegentPayments.{AgentAuthority, CompletionActor, PaymentIntent}

  @impl true
  def validate(changeset, opts, %{actor: %CompletionActor{} = actor}) do
    intent = Ash.Changeset.get_argument(changeset, :intent)

    if allowed?(actor, intent, opts[:kind], opts[:target_type]) and
         intent.target_id == Ash.Changeset.get_attribute(changeset, :id) and
         intent.id == Ash.Changeset.get_attribute(changeset, :payment_intent_id),
       do: :ok,
       else: refused()
  end

  def validate(_changeset, _opts, %{actor: %{role: :payment_completion}}), do: refused()
  def validate(_changeset, _opts, _context), do: :ok

  @doc "Check the canonical completion identity against the frozen local payment."
  def allowed?(%CompletionActor{} = actor, %PaymentIntent{status: :settled} = intent, kind, type),
    do:
      intent.site == "patchbay" and intent.target_type == type and
        AgentAuthority.completion_for?(actor, intent, kind)

  def allowed?(_actor, _intent, _kind, _type), do: false

  @doc "Offers admit ordinary payers or their canonical, intent-bound completion identity."
  def authorize(%{role: :payment_completion} = actor, intent, kind, type) do
    if allowed?(actor, intent, kind, type),
      do: :ok,
      else: RegentPayments.AgentAuthority.refused()
  end

  def authorize(_actor, _intent, _kind, _type), do: :ok

  defp refused,
    do: {:error, field: :intent, message: "must match the original settled payment and target"}
end
