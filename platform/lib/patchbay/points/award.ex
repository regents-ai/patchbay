defmodule Patchbay.Points.Award do
  @moduledoc """
  The template's inline signal listener. Each signal is offered to Regent Points
  in the transaction that emitted it. While a rule is off nothing is queued.

    * Credits a purchase now holds (`credits.purchase_settled`), from
      `RegentCredits.Signals`. Credits is one Regents ledger, so every site
      names it "regents" and a purchase earns once.
    * A new Regent account (`account.activated`), from
      `Patchbay.Accounts.Signals`. The account is one Regents account on
      every site, so it is named "regents" too.
    * An agent paired with its person (`agent.activated`), from
      `RegentAgents.Signals`, keyed by the pairing.
  """

  use Ash.Resource,
    domain: Patchbay.Points,
    authorizers: [Ash.Policy.Authorizer]

  signals_in do
    from Patchbay.Accounts.Signals do
      on(:account_registered, :account_registered)
    end

    from RegentAgents.Signals do
      on(:agent_paired, :agent_paired)
    end

    from RegentCredits.Signals do
      on(:purchase_credited, :purchase_credited, action: :credits_purchase)
      on(:purchase_attributed, :purchase_attributed, action: :credits_purchase)
    end
  end

  actions do
    action :account_registered do
      argument(:signal, :struct, allow_nil?: false)

      run(fn %{arguments: %{signal: signal}}, _context ->
        record(%{
          rule_id: "account.activated",
          source_app: "regents",
          source_kind: "account",
          source_event_key: to_string(signal.account_id)
        })
      end)
    end

    action :agent_paired do
      argument(:signal, :struct, allow_nil?: false)

      run(fn %{arguments: %{signal: signal}}, _context ->
        record(%{
          rule_id: "agent.activated",
          source_app: Patchbay.Points.app(),
          source_kind: "pairing",
          source_event_key: signal.paired_agent_id
        })
      end)
    end

    action :credits_purchase do
      argument(:signal, :struct, allow_nil?: false)

      run(fn %{arguments: %{signal: signal}}, _context ->
        record(%{
          rule_id: "credits.purchase_settled",
          source_app: "regents",
          source_kind: "credits_purchase",
          source_event_key: signal.purchase_id
        })
      end)
    end
  end

  defp record(reference) do
    with {:ok, _event} <- RegentPoints.record_event(reference, actor: %{role: :system}),
         do: :ok
  end

  policies do
    # Reached through the signals after the emitting action was allowed.
    # Records as the site's existing system actor, never as the caller.
    policy always() do
      authorize_if(always())
    end
  end
end
