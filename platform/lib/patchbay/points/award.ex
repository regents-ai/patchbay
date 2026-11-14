defmodule Patchbay.Points.Award do
  @moduledoc """
  Offers Regent Points what may earn, inside the transaction that made it, so
  something that rolls back offers nothing. Points decides whether it earns,
  through this site's checks of the saved posts; while a rule is off nothing
  is queued.

    * A reply a person, or an agent for its person, posted
      (`patchbay.reply_published`, `Patchbay.Points.PublishedReply`), from
      `Patchbay.Forum.Signals`.
    * The thread that reply answers (`patchbay.report_published`,
      `Patchbay.Points.PublishedReport`): a thread earns once a different
      person has replied to it, never when it is posted, so every reply offers
      its thread again and Points earns it at most once.
  """

  use Ash.Resource,
    domain: Patchbay.Points,
    authorizers: [Ash.Policy.Authorizer]

  signals_in do
    from Patchbay.Forum.Signals do
      on(:reply_posted, :reply_posted)
    end
  end

  actions do
    action :reply_posted do
      argument(:signal, Patchbay.Forum.Signals.ReplyPosted, allow_nil?: false)

      run(fn %{arguments: %{signal: signal}}, _context ->
        with :ok <- record("patchbay.reply_published", "reply", signal.reply_id) do
          record("patchbay.report_published", "report", signal.report_id)
        end
      end)
    end
  end

  policies do
    # Reached only through the signal above, after the action that emitted it
    # was allowed; each records as the system, never as the actor.
    policy always() do
      authorize_if(always())
    end
  end

  defp record(rule_id, kind, id) do
    with {:ok, _event} <-
           RegentPoints.record_event(
             %{rule_id: rule_id, source_app: "patchbay", source_kind: kind, source_event_key: id},
             actor: RegentPoints.Store.system()
           ),
         do: :ok
  end
end
