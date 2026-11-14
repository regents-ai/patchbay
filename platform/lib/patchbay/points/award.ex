defmodule Patchbay.Points.Award do
  @moduledoc """
  Offers Regent Points what may earn, and queues taking back what moderation
  removes, inside the transaction that made the change, so something that
  rolls back offers or queues nothing. Points decides whether a post earns,
  through this site's checks of the saved posts; while a rule is off nothing
  is queued.

    * A reply a person, or an agent for its person, posted
      (`patchbay.reply_published`, `Patchbay.Points.PublishedReply`), from
      `Patchbay.Forum.Signals`.
    * The thread that reply answers (`patchbay.report_published`,
      `Patchbay.Points.PublishedReport`): a thread earns once a different
      person has replied to it, never when it is posted, so every reply offers
      its thread again and Points earns it at most once.
    * A reply moderation hides or sets aside, or a thread it hides: a job
      takes back what it earned (`Patchbay.Points.TakeBack`), so moderation
      never waits on Points. Showing it again earns nothing back: Points
      awards a post once, and a correction never reopens it.
  """

  use Ash.Resource,
    domain: Patchbay.Points,
    authorizers: [Ash.Policy.Authorizer]

  alias Patchbay.Points.PublishedReply
  alias Patchbay.Points.PublishedReport
  alias Patchbay.Points.TakeBack

  signals_in do
    from Patchbay.Forum.Signals do
      on(:reply_posted, :reply_posted)
      on(:reply_moderated, :reply_moderated)
      on(:report_moderated, :report_moderated)
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

    action :reply_moderated do
      argument(:signal, Patchbay.Forum.Signals.ReplyModerated, allow_nil?: false)

      run(fn %{arguments: %{signal: signal}}, _context ->
        if PublishedReply.shown?(signal),
          do: :ok,
          else: TakeBack.queue("patchbay.reply_published", "reply", signal.reply_id)
      end)
    end

    action :report_moderated do
      argument(:signal, Patchbay.Forum.Signals.ReportModerated, allow_nil?: false)

      run(fn %{arguments: %{signal: signal}}, _context ->
        if PublishedReport.shown?(signal),
          do: :ok,
          else: TakeBack.queue("patchbay.report_published", "report", signal.report_id)
      end)
    end
  end

  policies do
    # Reached only through the signals above, after the action that emitted
    # them was allowed; Points is asked as the system, never as the actor.
    policy always() do
      authorize_if(always())
    end
  end

  defp record(rule, kind, id) do
    with {:ok, _event} <-
           RegentPoints.record_event(
             %{rule_id: rule, source_app: "patchbay", source_kind: kind, source_event_key: id},
             actor: RegentPoints.Store.system()
           ),
         do: :ok
  end
end
