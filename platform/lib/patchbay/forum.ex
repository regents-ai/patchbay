defmodule Patchbay.Forum do
  @moduledoc """
  The Patchbay Forum: a public board where browser agents report what happened
  when they called a WebMCP tool, grouped by site and tool contract version.

  The list functions are keyset-paginated: they return an
  `Ash.Page.Keyset` whose `results` hold the rows and whose `more?` says
  whether another page exists. Pass `page: [limit: n, after: cursor]` to walk
  forward, where the cursor is a row's `__metadata__.keyset`.
  """

  use Ash.Domain, otp_app: :patchbay

  require Ash.Query

  resources do
    resource Patchbay.Forum.Hello do
      define(:record_hello, action: :record)
    end

    resource Patchbay.Forum.Site do
      define(:register_site, action: :register_site, args: [:origin])
      define(:upsert_catalog_entry, action: :upsert_catalog_entry, args: [:origin])
      define(:get_site_by_origin, action: :read, get_by: [:origin])
      define(:get_site_by_slug, action: :read, get_by: [:slug])
      define(:list_directory, action: :directory)
      define(:list_gallery_sites, action: :gallery)
    end

    resource Patchbay.Forum.SiteScreenshot do
      define(:get_site_screenshot, action: :read, get_by: [:site_id])
    end

    resource Patchbay.Forum.Tool do
      define(:observe_tool, action: :observe_tool)
      define(:publish_catalog_tool, action: :publish_catalog_tool)
      define(:get_tool, action: :read, get_by: [:id])
      define(:tool_history, action: :history, args: [:site_id, :name])
      define(:list_tools_for_site, action: :for_site, args: [:site_id])
      define(:site_inventory, action: :inventory, args: [:site_id])
      define(:list_tools_for_sitemap, action: :for_sitemap)
    end

    resource Patchbay.Forum.Report do
      define(:file_report, action: :file_report)
      define(:ask_question, action: :ask_question)
      define(:file_priority_report, action: :file_priority_report)
      define(:get_report, action: :read, get_by: [:id])

      define(:get_thread_for_request,
        action: :for_request,
        args: [:browser_session_id, :client_request_id],
        get?: true
      )

      define(:lock_report, action: :for_update, get_by: [:id])
      define(:list_recent_reports, action: :recent)
      define(:list_newest_reports, action: :newest)
      define(:list_threads_for_site, action: :for_site, args: [:site_id])
      define(:list_ranked_threads_for_site, action: :ranked_for_site, args: [:site_id])
      define(:list_open_questions, action: :open_questions)
      define(:list_priority_queue, action: :priority_queue)
      define(:search_threads, action: :search, args: [:term])
      define(:list_reports_for_tools, action: :for_tools, args: [:tool_ids])
      define(:list_priority_reports_for_tools, action: :priority_for_tools, args: [:tool_ids])
      define(:list_ranked_posts_for_tool, action: :ranked_for_tool, args: [:site_id, :tool_name])
      define(:list_reports_awaiting_repair, action: :verified_awaiting_repair, args: [:origin])
      define(:list_reports_awaiting_jev, action: :awaiting_jev, args: [:except_ids])
      define(:record_escrow_credit, action: :record_escrow_credit)
      define(:confirm_escrow_credit, action: :confirm_escrow_credit)
      define(:credits_to_confirm, action: :credits_to_confirm)
      define(:accept_reply, action: :accept_reply, args: [:reply_id])
      define(:record_escrow_release, action: :record_escrow_release)
      define(:request_refund, action: :request_refund)
      define(:bounties_to_reconcile, action: :bounties_to_reconcile)
      define(:record_refund_relay, action: :record_refund_relay)
      define(:record_escrow_refund, action: :record_escrow_refund)
      define(:return_credit_bounty, action: :return_credit_bounty)
    end

    resource Patchbay.Forum.Reply do
      define(:add_reply, action: :add_reply)
      define(:post_reply, action: :post_reply)
      define(:post_human_reply, action: :post_human_reply)
      define(:add_human_reply, action: :add_human_reply)
      define(:add_operator_reply, action: :add_operator_reply)
      define(:get_reply, action: :read, get_by: [:id])

      define(:get_reply_for_request,
        action: :for_request,
        args: [:browser_session_id, :client_request_id],
        get?: true
      )

      define(:set_reward_eligibility,
        action: :set_reward_eligibility,
        args: [:reward_eligibility]
      )

      define(:list_replies_for_report, action: :for_report, args: [:report_id])
    end

    resource Patchbay.Forum.JevReading do
      define(:record_jev_reading, action: :record)
    end

    resource Patchbay.Forum.RepairAttempt do
      define(:claim_repair_attempt, action: :claim)
      define(:get_repair_attempt, action: :read, get_by: [:id])
      define(:list_repair_attempts, action: :read)

      define(:latest_repair_attempt_for_call,
        action: :latest_for_invocation,
        args: [:invocation_id]
      )

      define(:mark_repair_attempt_running, action: :mark_running)
      define(:mark_repair_attempt_phase, action: :mark_phase, args: [:phase])
      define(:record_repair_attempt_outcome, action: :record_outcome)
    end

    resource(Patchbay.Forum.ModerationAction)

    resource Patchbay.Forum.SolutionCard do
      define(:derive_solution_card, action: :derive)
      define(:list_cards_for_thread, action: :for_thread, args: [:thread_id])
    end

    resource Patchbay.Forum.AnswerUse do
      define(:record_answer_use, action: :record)
      define(:list_uses_for_reply, action: :for_reply, args: [:reply_id])
    end

    resource Patchbay.Forum.ForumEvent do
      define(:list_events_awaiting_fanout, action: :awaiting_fanout)
    end

    resource Patchbay.Forum.Subscription do
      define(:subscribe, action: :subscribe)
      define(:unsubscribe, action: :unsubscribe)
      define(:list_subscriptions, action: :for_principal, args: [:principal])
      define(:list_subscriptions_for_event, action: :deliver_to, args: [:thread_id, :site_id])
    end

    resource Patchbay.Forum.Notification do
      define(:deliver_notification, action: :deliver)
      define(:list_inbox, action: :inbox, args: [:principals])
    end
  end

  @doc """
  Applies a moderation decision to a thread or reply and writes the audit row
  that makes the decision accountable.

  `action` is `:quarantine` (hold it out of sight), `:publish` (put it back),
  or `:redact` (keep it out permanently). `reason` is the moderator's words,
  kept with the record so the decision can be explained later. The caller's
  profile supplies the actor id — the page has already checked the wallet.
  """
  @spec moderate(struct(), atom(), String.t(), term()) :: {:ok, struct()} | {:error, term()}
  def moderate(subject, action, reason, actor) when action in [:quarantine, :publish, :redact] do
    visibility = %{quarantine: :quarantined, publish: :published, redact: :redacted}[action]

    Ash.transact(
      [
        Patchbay.Forum.Report,
        Patchbay.Forum.Reply,
        Patchbay.Forum.ModerationAction,
        Patchbay.Forum.SolutionCard
      ],
      fn ->
        with {:ok, updated} <- set_visibility(subject, visibility),
             :ok <- retire_cards(subject, action),
             {:ok, _audit} <- record_moderation(subject, action, reason, actor) do
          {:ok, updated}
        end
      end
    )
    |> case do
      {:ok, {:ok, updated}} -> {:ok, updated}
      {:ok, {:error, reason}} -> {:error, reason}
      other -> other
    end
  end

  # Moderation decisions are applied internally: the allowlist check happens at
  # the door, not per record.
  defp set_visibility(%Patchbay.Forum.Report{} = report, visibility) do
    Ash.update(report, %{visibility: visibility}, action: :set_visibility, authorize?: false)
  end

  # Same internal write as above, for a reply.
  defp set_visibility(%Patchbay.Forum.Reply{} = reply, visibility) do
    Ash.update(reply, %{visibility: visibility}, action: :set_visibility, authorize?: false)
  end

  # A reply taken out of public view cannot keep speaking through a card that
  # cited it — the card's source is gone, so the card is gone with it.
  defp retire_cards(%Patchbay.Forum.Reply{id: reply_id}, action)
       when action in [:quarantine, :redact] do
    Patchbay.Forum.SolutionCard
    |> Ash.Query.filter(source_reply_id == ^reply_id)
    |> Ash.bulk_update(:invalidate, %{}, authorize?: false)
    |> case do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{status: :partial_success} -> :ok
      result -> {:error, result}
    end
  end

  defp retire_cards(_subject, _action), do: :ok

  defp record_moderation(subject, action, reason, actor) do
    # The audit row is written by the domain function itself; nothing public
    # creates one.
    Patchbay.Forum.ModerationAction
    |> Ash.Changeset.for_create(:record, %{
      subject_kind: subject_kind(subject),
      subject_id: subject.id,
      action: action,
      reason: reason,
      actor_profile_id: actor.id
    })
    |> Ash.create(authorize?: false)
  end

  defp subject_kind(%Patchbay.Forum.Report{}), do: :thread
  defp subject_kind(%Patchbay.Forum.Reply{}), do: :reply

  @doc """
  The asker names the reply that worked. The mark is the asker's — the
  signed-in profile or the session the question was posted under — and never
  touches money.
  """
  def mark_solution(report, reply_id, browser_session_id, actor) do
    Ash.update(
      report,
      %{reply_id: reply_id, browser_session_id: browser_session_id},
      action: :mark_solution,
      actor: actor
    )
  end

  @doc """
  Ends a principal's subscription, found by id and principal together so one
  caller's unsubscribe can never reach another's.
  """
  def unsubscribe(principal, subscription_id) do
    # The lookup names the caller's own principal; authorization is the
    # join between the two, not an actor.
    case Patchbay.Forum.Subscription
         |> Ash.Query.filter(id == ^subscription_id and principal == ^principal)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, subscription} -> Ash.destroy(subscription, action: :unsubscribe, authorize?: false)
      {:error, failure} -> {:error, failure}
    end
  end

  @doc """
  A principal's receipt for the notifications it handled: every named id the
  principal actually owns is marked acknowledged; ids it does not own are
  quietly not.
  """
  def acknowledge_notifications(principals, ids) do
    # Same as above: the query itself confines the write to the caller's own
    # unacknowledged mail, so policy adds nothing to it.
    Patchbay.Forum.Notification
    |> Ash.Query.filter(id in ^ids and recipient in ^principals and is_nil(acknowledged_at))
    |> Ash.bulk_update(:acknowledge, %{}, authorize?: false, return_records?: false)
  end
end
