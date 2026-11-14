defmodule Patchbay.Points.Award do
  @moduledoc """
  Offers Regent Points what may earn, and takes back what moderation removes,
  inside the transaction that made the change, so something that rolls back
  offers or takes back nothing. Points decides whether a post earns, through
  this site's checks of the saved posts; while a rule is off nothing is queued.

    * A reply a person, or an agent for its person, posted
      (`patchbay.reply_published`, `Patchbay.Points.PublishedReply`), from
      `Patchbay.Forum.Signals`.
    * The thread that reply answers (`patchbay.report_published`,
      `Patchbay.Points.PublishedReport`): a thread earns once a different
      person has replied to it, never when it is posted, so every reply offers
      its thread again and Points earns it at most once.
    * A reply moderation hides or sets aside, or a thread it hides, after it
      earned: Points takes the whole award back with its own correction
      (`RegentPoints.reverse/5`), once, however many times moderation speaks
      on it again. Showing it again earns nothing back: Points awards a post
      once, and a correction never reopens it.
  """

  use Ash.Resource,
    domain: Patchbay.Points,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  alias Patchbay.Points.PublishedReply
  alias Patchbay.Points.PublishedReport
  alias RegentPoints.Entry
  alias RegentPoints.Event
  alias RegentPoints.Rules
  alias RegentPoints.Store

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
          else: take_back("patchbay.reply_published", "reply", signal.reply_id)
      end)
    end

    action :report_moderated do
      argument(:signal, Patchbay.Forum.Signals.ReportModerated, allow_nil?: false)

      run(fn %{arguments: %{signal: signal}}, _context ->
        if PublishedReport.shown?(signal),
          do: :ok,
          else: take_back("patchbay.report_published", "report", signal.report_id)
      end)
    end
  end

  policies do
    # Reached only through the signals above, after the action that emitted
    # them was allowed; each records and corrects as the system, never as the
    # actor.
    policy always() do
      authorize_if(always())
    end
  end

  defp record(rule, kind, id) do
    with {:ok, _event} <-
           RegentPoints.record_event(
             %{rule_id: rule, source_app: "patchbay", source_kind: kind, source_event_key: id},
             actor: Store.system()
           ),
         do: :ok
  end

  # The award the post earned under this rule, if it earned any points, is
  # corrected to nothing. One correction key for every word moderation gives
  # on the post, so Points answers a second one with the first correction.
  defp take_back(rule, kind, id) do
    program = Rules.program()

    events =
      Ash.Query.filter(
        Event,
        program_id == ^program and rule_id == ^rule and source_app == "patchbay" and
          source_kind == ^kind and source_event_key == ^id
      )

    with {:ok, [event]} <- RegentPoints.read_events(query: events, actor: Store.system()),
         awards =
           Ash.Query.filter(Entry, program_id == ^program and award_key == ^event.award_key),
         {:ok, [%{points_micro_delta: points} = award]} when points > 0 <-
           RegentPoints.read_entries(query: awards, actor: Store.system()),
         {:ok, _correction} <-
           RegentPoints.reverse(award.id, "moderation", points, "moderated",
             actor: Store.system()
           ) do
      :ok
    else
      {:ok, _nothing_earned} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
