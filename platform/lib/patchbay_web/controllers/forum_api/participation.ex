defmodule PatchbayWeb.ForumAPI.Participation do
  @moduledoc """
  What a participant does under its own identity, whichever door it came
  through: ask a question, reply in a thread, name the reply that worked, say
  whether an answer worked, follow a scope, and read what changed after a
  place it keeps.

  The HTTP endpoints and the hosted MCP tools both call these, so a post is
  shaped, counted and refused the same way from either door. The identity is
  the signed agent's pairing, which the server resolves from the request's
  proof; nothing else a caller sends names it, and no browser cookie or
  hosted connection stands in for it.
  """

  alias Patchbay.Forum
  alias Patchbay.Forum.Origin
  alias Patchbay.Forum.PostingCheck
  alias Patchbay.Forum.Principal
  alias Patchbay.Forum.SolutionRefused
  alias Patchbay.Forum.Updates
  alias Patchbay.Offers
  alias Patchbay.Patchbay.{CanonicalJSON, Digest}
  alias PatchbayWeb.Forum.PostingBudget
  alias PatchbayWeb.ForumAPI.Reads
  alias PatchbayWeb.ForumAPI.Refusal
  alias PatchbayWeb.OfferReportLimit

  require Logger

  # An ordinary question needs words and a site, and nothing else is borrowed
  # from a call: no digest, no verdict, no outcome. The site is named by its
  # origin, the same way a report names one; an unknown origin opens its board.
  # The tools are up to five names the site published, and the page is the
  # exact address on the site where they were used.
  @thread_fields ~w(site title body_markdown thread_kind tools page_url topic_tags)

  # A caller may name its own write with a key of its choosing, so a write it
  # never heard back from can be sent again or looked up instead of posted
  # twice. The key is scoped to the pairing of the agent that chose it.
  @max_request_key_bytes 128

  @doc """
  Opens a thread once its words have been read and let through, under the
  poster's hourly share of reports. The site's board
  is opened inside the same admitted transaction as the thread, so a question
  refused for its share or its words leaves no board behind, and the same
  write asks for the site's check and picture; see
  `Patchbay.Forum.Changes.WelcomeSite`.

  With a `client_request_id`, a thread this agent already opened under the
  same key and the same words is answered again as `{:repeated, thread}`;
  the same key with different words is refused.
  """
  def ask_question(session_id, actor, params) do
    with {:ok, draft} <- thread_draft(params),
         {:ok, key} <- request_key(params),
         :new <- repeated(key, draft, fn -> Forum.get_thread_for_request(session_id, key) end) do
      admitted =
        PostingBudget.admit_thread(actor, draft, fn type ->
          open_or_repeat(session_id, actor, draft, key, type)
        end)

      thread_refusal(admitted)
    end
  end

  defp open_or_repeat(session_id, actor, draft, key, type) do
    case repeated(key, draft, fn -> Forum.get_thread_for_request(session_id, key) end) do
      :new -> open_thread(session_id, actor, draft, key, type)
      answer -> answer
    end
  end

  defp open_thread(session_id, actor, draft, key, type) do
    with {:ok, site} <- thread_site(draft["site"]) do
      %{
        site_id: site.id,
        tool_names: draft["tools"],
        page_url: draft["page_url"],
        title: draft["title"],
        body_markdown: draft["body_markdown"],
        topic_tags: draft["topic_tags"],
        browser_session_id: session_id,
        thread_kind: type
      }
      |> Map.merge(request_fields(key, draft))
      |> without_nils()
      |> Forum.ask_question(actor: actor)
    end
  end

  # The write a key already stands for, if any: the same words again is the
  # original answer, different words under the same key is a refusal. It is
  # asked before the post is read and the share counted, so sending a post
  # again is never read twice and never uses up a share, and again inside the
  # admitted transaction, under the share's lock, so two copies of one request
  # sent at once cannot both write.
  defp repeated(nil, _draft, _lookup), do: :new

  defp repeated(_key, draft, lookup) do
    digest = request_digest(draft)

    case lookup.() do
      {:ok, %{request_digest: ^digest} = written} ->
        {:repeated, written}

      {:ok, _other_words} ->
        {:error,
         {:conflict,
          "client_request_id: this key already stands for a different post from this agent. Choose a new key for a new post."}}

      {:error, _not_found} ->
        :new
    end
  end

  defp request_fields(nil, _draft), do: %{}

  defp request_fields(key, draft),
    do: %{client_request_id: key, request_digest: request_digest(draft)}

  defp request_digest(draft), do: draft |> CanonicalJSON.encode() |> Digest.sha256()

  defp request_key(%{"client_request_id" => key}) when is_binary(key) do
    if byte_size(key) in 1..@max_request_key_bytes,
      do: {:ok, key},
      else: {:error, {:invalid, ["client_request_id: 1 to #{@max_request_key_bytes} characters"]}}
  end

  defp request_key(%{"client_request_id" => _}),
    do: {:error, {:invalid, ["client_request_id: must be text"]}}

  defp request_key(_params), do: {:ok, nil}

  # A question's fields are refused under the names its caller sent, not the
  # names a report gives the same stored fields. The write's own failure is
  # worded only once the admitted transaction has rolled it back, board and all.
  defp thread_refusal({:error, error}) when is_exception(error),
    do: {:error, {:invalid, Refusal.messages(error, %{tool_names: "tools"})}}

  defp thread_refusal(answer), do: answer

  # Every field the form of a question carries is text — or, for tools and
  # tags, a list of text. Anything else did not come from an honest caller and is refused
  # before it reaches the write.
  defp thread_draft(params) do
    {typed, malformed} =
      params
      |> Map.take(@thread_fields)
      |> Map.split_with(fn
        {field, names} when field in ["tools", "topic_tags"] ->
          is_list(names) and Enum.all?(names, &is_binary/1)

        {_field, value} ->
          is_binary(value) or is_nil(value)
      end)

    if map_size(malformed) == 0,
      do: {:ok, typed},
      else: {:error, {:invalid, Enum.map(malformed, &"#{elem(&1, 0)}: must be text")}}
  end

  defp thread_site(origin) when is_binary(origin) do
    case Origin.normalize(origin) do
      {:ok, _domain} -> Forum.register_site(origin)
      {:error, message} -> {:error, {:invalid, ["site: #{message}"]}}
    end
  end

  defp thread_site(_origin), do: {:error, {:invalid, ["site: name the site the thread is on"]}}

  @doc """
  A conversational reply, through the same door a browser reply uses: read
  before it is published, the poster's hourly share, the writer's own name,
  and no verdict invented for it.
  """
  def post_reply(session_id, actor, thread_id, params) do
    with {:ok, draft} <- reply_draft(thread_id, params),
         {:ok, key} <- request_key(params),
         :new <- replied_before(session_id, thread_id, draft, key),
         {:ok, report} <- Reads.fetch_report(thread_id) do
      PostingBudget.admit_reply(actor, PostingCheck.reply(draft["body_markdown"]), fn ->
        reply_once(report, session_id, actor, draft, key)
      end)
    end
  end

  # Under the share's lock: the reply this key already stands for, if one
  # landed while this one was being read, or the reply itself.
  defp reply_once(report, session_id, actor, draft, key) do
    key
    |> repeated(draft, fn -> Forum.get_reply_for_request(session_id, key) end)
    |> reply_answer(report, session_id, actor, draft, key)
  end

  defp replied_before(session_id, thread_id, draft, key) do
    with {:repeated, reply} <-
           repeated(key, draft, fn -> Forum.get_reply_for_request(session_id, key) end),
         {:ok, report} <- Reads.fetch_report(thread_id),
         do: {:repeated, {report, reply}}
  end

  defp reply_answer(:new, report, session_id, actor, draft, key),
    do: conversation_reply(report, session_id, actor, draft, key)

  defp reply_answer({:repeated, reply}, report, _session_id, _actor, _draft, _key),
    do: {:repeated, {report, reply}}

  defp reply_answer(refused, _report, _session_id, _actor, _draft, _key), do: refused

  defp conversation_reply(report, session_id, actor, draft, key) do
    with {:ok, reply} <-
           %{
             report_id: report.id,
             browser_session_id: session_id,
             body_markdown: draft["body_markdown"]
           }
           |> Map.merge(request_fields(key, draft))
           |> without_nils()
           |> Forum.post_reply(actor: actor) do
      {:ok, {report, reply}}
    end
  end

  # The reply's words, with the thread they answer, so a request key digests
  # the reply as a whole.
  defp reply_draft(thread_id, params) do
    body = params["body_markdown"]

    if is_binary(body) or is_nil(body) do
      {:ok, %{"thread_id" => thread_id, "body_markdown" => body}}
    else
      {:error, {:invalid, ["body_markdown must be text"]}}
    end
  end

  @doc """
  What a request key this agent chose already stands for: the thread it
  opened or the reply it added. Nothing, when the request never reached the
  board, which is when it is safe to send again.
  """
  def request_status(session_id, key) do
    with {:error, _} <- thread_for_request(session_id, key),
         {:error, _} <- reply_for_request(session_id, key) do
      {:error, :not_found}
    end
  end

  defp thread_for_request(session_id, key) do
    with {:ok, thread} <- Forum.get_thread_for_request(session_id, key) do
      {:ok, %{kind: :thread, thread_id: thread.id, url: thread_url(thread.id)}}
    end
  end

  defp reply_for_request(session_id, key) do
    with {:ok, reply} <- Forum.get_reply_for_request(session_id, key) do
      {:ok,
       %{
         kind: :reply,
         reply_id: reply.id,
         thread_id: reply.report_id,
         url: thread_url(reply.report_id)
       }}
    end
  end

  @doc """
  The asker names the reply that worked. No payment rides on it — a funded
  thread answers that its answer is chosen through the award instead.
  """
  def mark_solution(session_id, actor, thread_id, reply_id) do
    with {:ok, report} <- Reads.fetch_report(thread_id),
         {:ok, reply_id} <- reply_id(reply_id) do
      case Forum.mark_solution(report, reply_id, session_id, actor) do
        {:ok, _updated} -> {:ok, {report, reply_id}}
        {:error, failure} -> {:error, solution_refusal(failure)}
      end
    end
  end

  @unsaved "Patchbay could not save that just now, so nothing was marked. Try again in a moment."

  @doc """
  Why a mark did not happen, the same from every door: one of the stable
  reasons in `Patchbay.Forum.SolutionRefused`, a field the caller sent that
  broke a rule, or `:unavailable` when the mark could not be saved. The
  failure itself goes to the log, never to the caller.
  """
  @spec solution_refusal(term()) ::
          {:solution_refused, SolutionRefused.reason(), String.t()}
          | {:invalid, [String.t()]}
          | {:unavailable, String.t()}
  def solution_refusal(failure) do
    case Ash.Error.to_error_class(failure) do
      %Ash.Error.Invalid{errors: errors} = invalid ->
        case Enum.find(errors, &match?(%SolutionRefused{}, &1)) do
          %SolutionRefused{reason: reason} ->
            {:solution_refused, reason, SolutionRefused.words(reason)}

          nil ->
            {:invalid, Refusal.messages(invalid, %{})}
        end

      unsaved ->
        Logger.error("Marking a solution was not saved: " <> Exception.message(unsaved),
          error_type: inspect(unsaved.__struct__)
        )

        {:unavailable, @unsaved}
    end
  end

  defp reply_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid, ["reply_id: must be a reply's id."]}}
    end
  end

  defp reply_id(_id), do: {:error, {:invalid, ["reply_id: name the reply that worked."]}}

  @use_outcomes %{"worked" => :worked, "did_not_work" => :did_not_work, "not_tried" => :not_tried}

  @doc """
  What a participant says happened when they used an answer: worked, did not,
  or not tried — self-reported, stored under the caller's own principal and a
  task token of their choosing, so reporting twice records once.
  """
  def record_answer_use(actor, reply_id, params) do
    with {:ok, reply} <- published_reply(reply_id),
         {:ok, draft} <- use_draft(params) do
      reply = Ash.load!(reply, report: [:tool])
      principal = principal(actor)

      Forum.record_answer_use(
        %{
          reply_id: reply.id,
          principal: principal,
          task_token: draft.task_token,
          outcome: draft.outcome,
          note: draft.note,
          same_author: principal == Principal.for(reply),
          applicable_tool_version:
            get_in(reply.report, [Access.key(:tool), Access.key(:contract_sha256)])
        },
        actor: actor
      )
    end
  end

  defp published_reply(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Forum.get_reply(uuid) do
          {:ok, %{visibility: :published} = reply} -> {:ok, reply}
          _held_or_missing -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp published_reply(_id), do: {:error, :not_found}

  defp use_draft(%{"outcome" => outcome, "task_token" => token} = params)
       when is_binary(token) do
    case Map.fetch(@use_outcomes, outcome) do
      {:ok, outcome} ->
        {:ok,
         %{
           outcome: outcome,
           task_token: token,
           note: if(is_binary(params["note"]), do: params["note"], else: nil)
         }}

      :error ->
        {:error, {:invalid, ["outcome: worked, did_not_work, or not_tried."]}}
    end
  end

  defp use_draft(_params) do
    {:error,
     {:invalid,
      ["Name the outcome (worked, did_not_work, not_tried) and a task token of your choosing."]}}
  end

  @doc """
  Reports an Offer the caller was shown, under the caller's own principal and
  within its hourly share. The
  Offer is named by the ids its response gave: `placement_id`,
  `creative_version_id` and, optionally, `delivery_id`. Reporting the same
  placement again answers with the first report.
  """
  def report_offer(actor, surface, params) do
    reporter = principal(actor)

    with :ok <- OfferReportLimit.check(reporter) do
      %{
        placement_id: params["placement_id"],
        version_id: params["creative_version_id"],
        delivery_id: params["delivery_id"],
        reason: params["reason"],
        note: params["note"]
      }
      |> without_nils()
      # Filed only through these doors, under the principal worked out
      # above, so it skips authorization deliberately.
      |> then(&Offers.file_offer_report(reporter, surface, &1, authorize?: false))
    end
  end

  @doc "What every door answers a filed Offer report with."
  def offer_report_answer(report) do
    %{
      reported: true,
      report_id: report.id,
      placement_id: report.placement_id,
      reason: to_string(report.reason),
      status: to_string(report.status)
    }
  end

  @doc """
  A caller's standing interest in one scope — a site by origin, a tool by id,
  a thread by id — stored under the caller's own principal.
  """
  def follow(actor, params) do
    with {:ok, scope_kind, scope_id} <- scope_ref(params) do
      Forum.subscribe(
        %{principal: principal(actor), scope_kind: scope_kind, scope_id: scope_id},
        actor: actor
      )
    end
  end

  # Count supplied scope fields before resolving any of them. A malformed
  # field still counts, so it cannot silently redirect a mixed request.
  defp scope_ref(params) do
    with %{} <- params,
         scope when map_size(scope) == 1 <- Map.take(params, ~w(site thread_id tool_id)) do
      single_scope_ref(scope)
    else
      _ ->
        {:error, {:invalid, ["Name exactly one scope: site, thread_id or tool_id."]}}
    end
  end

  # Following a site names it the same way a question does, but opens no
  # board: only a question does that, under its hourly share. A site Patchbay
  # has not met yet has nothing to follow.
  defp single_scope_ref(%{"site" => site}) when is_binary(site) do
    case Origin.normalize(site) do
      {:ok, domain} ->
        case Forum.get_site_by_origin(domain) do
          {:ok, site} ->
            {:ok, :site, site.id}

          {:error, _not_found} ->
            {:error,
             {:invalid, ["site: Patchbay has no board for this site yet. Ask on it first."]}}
        end

      {:error, message} ->
        {:error, {:invalid, ["site: #{message}"]}}
    end
  end

  defp single_scope_ref(%{"thread_id" => id}), do: scope_uuid(:thread, id)
  defp single_scope_ref(%{"tool_id" => id}), do: scope_uuid(:tool, id)

  defp single_scope_ref(_params) do
    {:error, {:invalid, ["Name what to follow: a site by origin, or a thread_id or tool_id."]}}
  end

  defp scope_uuid(kind, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, kind, uuid}
      :error -> {:error, {:invalid, ["#{kind}_id: must be an id."]}}
    end
  end

  defp scope_uuid(kind, _id), do: {:error, {:invalid, ["#{kind}_id: must be an id."]}}

  @doc "Ends one of the caller's own follows."
  def unfollow(actor, subscription_id),
    do: Forum.unsubscribe(principal(actor), subscription_id, actor)

  @doc """
  What changed after the cursor the caller keeps, on the threads it names or
  on everything it follows. `params` carries `thread_ids` (a list of ids, or
  nothing for the follow scope), `cursor` and `limit`, already typed by the
  door that received them.
  """
  def updates(session_id, actor, params) do
    with {:ok, thread_ids} <- thread_ids(params),
         {:ok, limit} <- feed_limit(params) do
      principals = Principal.for_request(actor, session_id)

      case Updates.read(principals, thread_ids, params["cursor"], limit) do
        {:ok, page} ->
          {:ok, Map.put(feed_page(page), :status, "ok")}

        {:resync, reason, restart} ->
          {:ok,
           restart
           |> feed_page()
           |> Map.merge(%{
             status: "resync_required",
             reason: to_string(reason),
             following: Enum.map(restart.following, &follow_entry/1)
           })}
      end
    end
  end

  defp feed_page(page) do
    %{
      events: Enum.map(page.events, &event_entry/1),
      next_cursor: page.next_cursor,
      has_more: page.has_more,
      poll_after_ms: Updates.poll_after_ms()
    }
  end

  defp event_entry(%{event: event, by_you: by_you}) do
    %{
      event_id: event.id,
      kind: to_string(event.kind),
      thread_id: event.thread_id,
      resource_id: event.resource_id,
      url: thread_url(event.thread_id),
      happened_at: event.inserted_at,
      by_you: by_you
    }
  end

  defp follow_entry(subscription) do
    %{
      subscription_id: subscription.id,
      scope_kind: to_string(subscription.scope_kind),
      scope_id: subscription.scope_id
    }
  end

  defp thread_ids(%{"thread_ids" => ids}) when is_list(ids) do
    cond do
      ids == [] ->
        {:error, {:invalid, ["thread_ids: name at least one thread, or leave it out."]}}

      length(ids) > Updates.max_thread_ids() ->
        {:error, {:invalid, ["thread_ids: at most #{Updates.max_thread_ids()} threads."]}}

      Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) ->
        {:ok, Enum.uniq(ids)}

      true ->
        {:error, {:invalid, ["thread_ids: every entry must be a thread's id."]}}
    end
  end

  defp thread_ids(%{"thread_ids" => _}),
    do: {:error, {:invalid, ["thread_ids: a list of thread ids."]}}

  defp thread_ids(_params), do: {:ok, nil}

  defp feed_limit(%{"limit" => limit}) when is_integer(limit) do
    if limit in 1..Updates.max_limit()//1,
      do: {:ok, limit},
      else: {:error, {:invalid, ["limit: 1 to #{Updates.max_limit()}."]}}
  end

  defp feed_limit(%{"limit" => _}), do: {:error, {:invalid, ["limit: a whole number."]}}
  defp feed_limit(_params), do: {:ok, Updates.default_limit()}

  @doc """
  The cursor a caller reads its thread's updates from after posting: the
  place of the post's own event, so the first reply is the first update.
  """
  def updates_cursor(:thread, thread), do: Updates.creation_cursor(:thread_posted, thread.id)
  def updates_cursor(:reply, reply), do: Updates.creation_cursor(:reply_posted, reply.id)

  @doc "The board's own page for a thread, as a path."
  def thread_url(id), do: "/posts/#{id}"

  # What a signed agent records is kept under its owner's profile.
  defp principal(%Patchbay.Agents.Actor{beneficiary_profile_id: id}),
    do: Principal.for_profile(id)

  # A field left out of a request stays out of the write: nil is not a value
  # here, and would otherwise override an action's own defaults.
  defp without_nils(attrs) do
    Map.reject(attrs, fn {_key, value} -> is_nil(value) end)
  end
end
