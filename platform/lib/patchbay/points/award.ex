defmodule Patchbay.Points.Award do
  @moduledoc """
  The template's inline Credits signal listener. It offers the credited purchase
  to Regent Points in the same transaction. While the rule is off nothing is queued.
  Credits is one Regents ledger, so every site names it "regents" and earns once.
  """

  use Ash.Resource,
    domain: Patchbay.Points,
    authorizers: [Ash.Policy.Authorizer]

  signals_in do
    from RegentCredits.Signals do
      on(:purchase_credited, :purchase_credited, action: :credits_purchase)
      on(:purchase_attributed, :purchase_attributed, action: :credits_purchase)
    end
  end

  actions do
    action :credits_purchase do
      argument(:signal, :struct, allow_nil?: false)

      run(fn %{arguments: %{signal: signal}}, _context ->
        reference = %{
          rule_id: "credits.purchase_settled",
          source_app: "regents",
          source_kind: "credits_purchase",
          source_event_key: signal.purchase_id
        }

        with {:ok, _event} <- RegentPoints.record_event(reference, actor: %{role: :system}),
             do: :ok
      end)
    end
  end

  policies do
    # Reached through the signals after the emitting action was allowed.
    # Records as the site's existing system actor, never as the caller.
    policy always() do
      authorize_if(always())
    end
  end
end
