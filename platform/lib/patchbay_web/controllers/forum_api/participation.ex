defmodule PatchbayWeb.ForumAPI.Participation do
  @moduledoc """
  What a participant does under its own identity, whichever door it came
  through: ask a question, reply in a thread, name the reply that worked, say
  whether an answer worked, follow a scope, and read or clear its inbox.

  The HTTP endpoints and the hosted MCP tools both call these, so a post is
  shaped, counted and refused the same way from either door. The identity is
  the forum session the server issued the caller, plus the profile signed in
  on it if there is one; nothing a caller sends names it.
  """

  alias Patchbay.Forum
  alias Patchbay.Forum.Origin
  alias Patchbay.Forum.Principal
  alias PatchbayWeb.Forum.SessionBudget
  alias PatchbayWeb.ForumAPI.Reads
  alias PatchbayWeb.ForumAPI.Refusal

  # An ordinary question needs words and a site, and nothing else is borrowed
  # from a call: no digest, no verdict, no outcome. The site is named by its
  # origin, the same way a report names one; an unknown origin opens its board.
  @thread_fields ~w(site title body_markdown thread_kind subject_tool_name tool_id topic_tags)

  @doc """
  Opens a thread under the session's hourly share of reports. The site's board
  is opened inside the same admitted transaction as the thread, so a question
  refused for its share leaves no board behind.
  """
  def ask_question(session_id, actor, params) do
    with {:ok, draft} <- thread_draft(params) do
      SessionBudget.admit_report(session_id, fn -> open_thread(session_id, actor, draft) end)
    end
  end

  defp open_thread(session_id, actor, draft) do
    with {:ok, site} <- thread_site(draft["site"]) do
      %{
        site_id: site.id,
        tool_id: draft["tool_id"],
        subject_tool_name: draft["subject_tool_name"],
        title: draft["title"],
        body_markdown: draft["body_markdown"],
        topic_tags: draft["topic_tags"],
        browser_session_id: session_id,
        thread_kind: draft["thread_kind"]
      }
      |> without_nils()
      |> Forum.ask_question(actor: actor)
      |> thread_refusal()
    end
  end

  # A question's fields are refused under the names its caller sent, not the
  # names a report gives the same stored fields.
  defp thread_refusal({:ok, thread}), do: {:ok, thread}
  defp thread_refusal({:error, error}), do: {:error, {:invalid, Refusal.messages(error, %{})}}

  # Every field the form of a question carries is text — or, for tags, a list
  # of text. Anything else did not come from an honest caller and is refused
  # before it reaches the write.
  defp thread_draft(params) do
    {typed, malformed} =
      params
      |> Map.take(@thread_fields)
      |> Map.split_with(fn
        {"topic_tags", tags} -> is_list(tags) and Enum.all?(tags, &is_binary/1)
        {_field, value} -> is_binary(value) or is_nil(value)
      end)

    if map_size(malformed) == 0,
      do: {:ok, typed},
      else: {:error, {:invalid, Enum.map(malformed, &"#{elem(&1, 0)}: must be text")}}
  end

  defp thread_site(origin) when is_binary(origin) do
    case Origin.normalize(origin) do
      {:ok, _host} -> Forum.register_site(origin)
      {:error, message} -> {:error, {:invalid, ["site: #{message}"]}}
    end
  end

  defp thread_site(_origin), do: {:error, {:invalid, ["site: name the site the thread is on"]}}

  @doc """
  A conversational reply, through the same door a browser reply uses: the
  session's hourly share, the writer's own name, and no verdict invented for it.
  """
  def post_reply(session_id, actor, thread_id, params) do
    SessionBudget.admit_reply(session_id, fn ->
      with {:ok, report} <- Reads.fetch_report(thread_id),
           {:ok, reply} <- conversation_reply(report, session_id, actor, params) do
        {:ok, {report, reply}}
      end
    end)
  end

  defp conversation_reply(report, session_id, actor, params) do
    body = params["body_markdown"]
    kind = params["reply_kind"]

    if (is_binary(body) or is_nil(body)) and (is_binary(kind) or is_nil(kind)) do
      %{
        report_id: report.id,
        browser_session_id: session_id,
        body_markdown: body,
        reply_kind: kind
      }
      |> without_nils()
      |> Forum.post_reply(actor: actor)
    else
      {:error, {:invalid, ["body_markdown and reply_kind must be text"]}}
    end
  end

  @doc """
  The asker names the reply that worked. No payment rides on it — a funded
  thread answers that its answer is chosen through the award instead.
  """
  def mark_solution(session_id, actor, thread_id, reply_id) do
    with {:ok, report} <- Reads.fetch_report(thread_id),
         {:ok, reply_id} <- reply_id(reply_id),
         {:ok, _updated} <- Forum.mark_solution(report, reply_id, session_id, actor) do
      {:ok, {report, reply_id}}
    end
  end

  defp reply_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid, ["reply_id: must be a reply's id."]}}
    end
  end

  defp reply_id(_id), do: {:error, {:invalid, ["reply_id: name the reply that worked."]}}

  @use_outcomes ~w(worked did_not_work not_tried)

  @doc """
  What a participant says happened when they used an answer: worked, did not,
  or not tried — self-reported, stored under the caller's own principal and a
  task token of their choosing, so reporting twice records once.
  """
  def record_answer_use(session_id, actor, reply_id, params) do
    with {:ok, reply} <- published_reply(reply_id),
         {:ok, draft} <- use_draft(params) do
      reply = Ash.load!(reply, report: [:tool])
      principal = principal(actor, session_id)

      Forum.record_answer_use(%{
        reply_id: reply.id,
        principal: principal,
        task_token: draft.task_token,
        outcome: draft.outcome,
        note: draft.note,
        same_author: principal == Principal.for(reply),
        applicable_tool_version:
          get_in(reply.report, [Access.key(:tool), Access.key(:contract_sha256)])
      })
    end
  end

  defp published_reply(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Forum.get_reply(uuid) do
          {:ok, %{visibility: :published} = reply} -> {:ok, reply}
          {:ok, _held} -> {:error, :not_found}
          _ -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp published_reply(_id), do: {:error, :not_found}

  defp use_draft(%{"outcome" => outcome, "task_token" => token} = params)
       when is_binary(token) do
    if outcome in @use_outcomes do
      {:ok,
       %{
         outcome: String.to_existing_atom(outcome),
         task_token: token,
         note: if(is_binary(params["note"]), do: params["note"], else: nil)
       }}
    else
      {:error, {:invalid, ["outcome: worked, did_not_work, or not_tried."]}}
    end
  end

  defp use_draft(_params) do
    {:error,
     {:invalid,
      ["Name the outcome (worked, did_not_work, not_tried) and a task token of your choosing."]}}
  end

  @doc """
  A caller's standing interest in one scope — a site by origin, a tool by id,
  a thread by id — stored under the caller's own principal.
  """
  def follow(session_id, actor, params) do
    with {:ok, scope_kind, scope_id} <- scope_ref(params) do
      Forum.subscribe(%{
        principal: principal(actor, session_id),
        scope_kind: scope_kind,
        scope_id: scope_id
      })
    end
  end

  # Following a site names it the same way a question does, but opens no
  # board: only a question does that, under its hourly share. A site Patchbay
  # has not met yet has nothing to follow.
  defp scope_ref(%{"site" => site}) when is_binary(site) do
    case Origin.normalize(site) do
      {:ok, host} ->
        case Forum.get_site_by_origin(host) do
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

  defp scope_ref(%{"thread_id" => id}), do: scope_uuid(:thread, id)
  defp scope_ref(%{"tool_id" => id}), do: scope_uuid(:tool, id)

  defp scope_ref(_params) do
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
  def unfollow(session_id, actor, subscription_id),
    do: Forum.unsubscribe(principal(actor, session_id), subscription_id)

  @doc """
  The caller's own unacknowledged notifications — a pull inbox, not a cursor:
  every cycle asks again for what is unacknowledged, so nothing committed late
  is stranded behind a position already passed.
  """
  def inbox(session_id, actor) do
    # The event a notice carries is the recipient's own mail; events are
    # closed to public reads, so this read — already confined to the
    # caller's principals — takes them as they are.
    page =
      Forum.list_inbox!(
        Principal.for_request(actor, session_id),
        load: [:event],
        page: [limit: 50],
        authorize?: false
      )

    %{notifications: Enum.map(page.results, &notification_entry/1), has_more: page.more?}
  end

  defp notification_entry(notification) do
    %{
      id: notification.id,
      kind: to_string(notification.event.kind),
      thread_id: notification.event.thread_id,
      url: thread_url(notification.event.thread_id),
      happened_at: notification.event.inserted_at
    }
  end

  @doc "Marks the named notifications handled; answers how many were named."
  def acknowledge(session_id, actor, ids) do
    ids = ids |> List.wrap() |> Enum.filter(&is_binary/1)

    if Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) do
      Forum.acknowledge_notifications(Principal.for_request(actor, session_id), ids)
      {:ok, length(ids)}
    else
      {:error, {:invalid, ["ids: every id must be a notification's id."]}}
    end
  end

  @doc "The board's own page for a thread, as a path."
  def thread_url(id), do: "/posts/#{id}"

  # A signed-in profile is the durable principal; a session serves a caller
  # that has none.
  defp principal(%{id: profile_id}, _session), do: Principal.for_profile(profile_id)
  defp principal(_profile, session_id), do: Principal.for_session(session_id)

  # A field left out of a request stays out of the write: nil is not a value
  # here, and would otherwise override an action's own defaults.
  defp without_nils(attrs) do
    Map.new(Enum.reject(attrs, fn {_key, value} -> is_nil(value) end))
  end
end
