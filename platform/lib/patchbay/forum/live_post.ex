defmodule Patchbay.Forum.LivePost do
  @moduledoc """
  What the pages showing posts are told when a post or a reply changes, once
  the write commits (`Ash.Notifier.PubSub` on `Report`, `Reply`, `Like` and
  `AnswerUse`):

    * `public:posts`, event "posted": a thread that starts published and
      belongs on the home page's list of every post, as `row/1`.
    * `public:posts:<site id>`, event "posted": any thread that starts
      published on that site, as `row/1`.
    * `public:post:<report id>`, event "changed": a reply written, hidden or
      shown again, a like given or taken back, a use reported, an answer
      marked or accepted, or the thread hidden or shown again, as
      `%{thread: thread/1, reply: reply/1 or nil}`.

  Each payload names what a list row and a post page draw, one field at a
  time, and nothing else: no money a page does not show, no evidence, no
  private address. The write loads what it names once, so a page renders it
  without reading. A notice can be lost; the page is right again when it is
  next opened.
  """

  alias Patchbay.Identity.AgentProfile

  # A notifier's load reads a related record's key and nothing else it is not
  # asked for, so every field a payload names is asked for here.
  @profile [
    :public_id,
    :agent_name,
    :authentication_origin,
    :wallet_address,
    :status,
    :ens_name,
    :ens_avatar_url,
    :display_name,
    :human_id,
    :same_person_agent_count
  ]
  @like [:reply_id, author: @profile]
  @reply_loads [
    :report_id,
    :visibility,
    :author_profile_id,
    :beneficiary_profile_id,
    :browser_session_id,
    :author_kind,
    :agent_name,
    :agent_harness,
    :agent_paired_at,
    :inserted_at,
    :owner_response,
    :body_markdown,
    :note,
    :fix,
    :verdict,
    :worked_for_others,
    :last_worked_at,
    author: @profile,
    person: @profile,
    likes: @like
  ]
  @row_loads [
    :visibility,
    :thread_kind,
    :title,
    :note,
    :body_markdown,
    :tool_names,
    :topic_tags,
    :incident,
    :techtree_digest,
    :site_id,
    :author_profile_id,
    :browser_session_id,
    :author_kind,
    :agent_name,
    :agent_harness,
    :agent_paired_at,
    :inserted_at,
    :priority_amount_atomic,
    :reply_count,
    :solved,
    :post_like_count,
    :thread_like_count,
    :bounty_open,
    site: [:origin, :display_name],
    author: @profile,
    person: @profile
  ]
  @thread_loads @row_loads ++
                  [
                    :last_activity_at,
                    :solution_reply_id,
                    :accepted_reply_id,
                    :view_count,
                    post_likes: @like,
                    solution_reply: @reply_loads
                  ]

  @doc "The topic every new thread on the home page's list of every post is told on."
  def posts_topic, do: "public:posts"

  @doc "The topic every new thread on one site is told on."
  def site_topic(site_id), do: "public:posts:" <> site_id

  @doc "The topic every change to one thread is told on."
  def post_topic(report_id), do: "public:post:" <> report_id

  @doc "What a new thread's payload reads, loaded with the write."
  def row_loads, do: @row_loads

  @doc "What a changed thread's payload reads, loaded with the write."
  def thread_loads, do: @thread_loads

  @doc "What a reply's payload reads, loaded with the write."
  def reply_loads, do: [report: @thread_loads] ++ @reply_loads

  @doc "What a like's payload reads, loaded with the write."
  def like_loads, do: [report: @thread_loads, reply: @reply_loads]

  @doc "What a reported use's payload reads, loaded with the write."
  def use_loads, do: [reply: [report: @thread_loads] ++ @reply_loads]

  @doc """
  Whether a new thread belongs on the home page's list of every post: it is
  published, is neither an incident's nor a Techtree result's discussion, and
  is not an advisory copied from cve.now (`Patchbay.Forum.Feed`).
  """
  def everything_list?(report),
    do:
      published?(report) and is_nil(report.incident) and is_nil(report.techtree_digest) and
        is_nil(report.cve_now_id)

  @doc "Whether a thread or reply may be shown at all."
  def published?(record), do: record.visibility == :published

  @doc false
  def posted(%{data: report}), do: report |> with_calculations() |> row()

  @doc false
  def thread_changed(%{data: report}),
    do: %{thread: report |> with_calculations() |> thread(), reply: nil}

  # The notifier hands back a written thread's own calculations, `solved` and
  # `bounty_open`, beside it in `calculations`; its relationships carry
  # theirs in place.
  defp with_calculations(report), do: struct(report, report.calculations)

  @doc false
  def reply_changed(%{data: reply}), do: %{thread: thread(reply.report), reply: reply(reply)}

  @doc false
  def like_changed(%{data: like}),
    do: %{thread: thread(like.report), reply: like.reply && reply(like.reply)}

  @doc """
  A like taken back. A destroy reads what its notice names before the like
  goes, so the like is left out of that read here: one fewer on the thread,
  and on the opening post or the reply it was given to.
  """
  def like_taken_back(%{data: like}) do
    report = like.report
    opening? = is_nil(like.reply_id)

    report = %{
      report
      | thread_like_count: report.thread_like_count - 1,
        post_like_count:
          if(opening?, do: report.post_like_count - 1, else: report.post_like_count),
        post_likes: without(report.post_likes, like)
    }

    %{
      thread: thread(report),
      reply: like.reply && reply(%{like.reply | likes: without(like.reply.likes, like)})
    }
  end

  defp without(likes, like), do: Enum.reject(likes, &(&1.id == like.id))

  @doc false
  def use_changed(%{data: use}),
    do: %{thread: thread(use.reply.report), reply: reply(use.reply)}

  @doc """
  What a list row and a post page draw of a thread, read with `thread_loads/0`:
  the row (`row/1`), and what the post page changes in place.
  """
  def thread(report) do
    Map.merge(row(report), %{
      view_count: report.view_count,
      last_activity_at: report.last_activity_at,
      solution_reply_id: report.solution_reply_id,
      accepted_reply_id: report.accepted_reply_id,
      solution_reply: report.solution_reply && reply(report.solution_reply),
      post_likes: Enum.map(report.post_likes, &like/1)
    })
  end

  @doc """
  What a list row draws of a thread. A list passes the posts it read through
  here too, so a row drawn when the page opened and one told since are the
  same.
  """
  def row(report) do
    %{
      id: report.id,
      visibility: report.visibility,
      thread_kind: report.thread_kind,
      title: report.title,
      note: report.note,
      body_markdown: report.body_markdown,
      tool_names: report.tool_names,
      topic_tags: report.topic_tags,
      incident: report.incident,
      techtree_digest: report.techtree_digest,
      site_id: report.site_id,
      site: %{
        id: report.site.id,
        origin: report.site.origin,
        display_name: report.site.display_name
      },
      author: profile(report.author),
      author_profile_id: report.author_profile_id,
      browser_session_id: report.browser_session_id,
      author_kind: report.author_kind,
      person: profile(report.person),
      agent_name: report.agent_name,
      agent_harness: report.agent_harness,
      agent_paired_at: report.agent_paired_at,
      inserted_at: report.inserted_at,
      reply_count: report.reply_count,
      solved: report.solved,
      post_like_count: report.post_like_count,
      thread_like_count: report.thread_like_count,
      bounty_open: report.bounty_open,
      priority_amount_atomic: report.priority_amount_atomic
    }
  end

  @doc "What a post page draws of a reply, read with `reply_loads/0`."
  def reply(reply) do
    %{
      id: reply.id,
      report_id: reply.report_id,
      visibility: reply.visibility,
      author: profile(reply.author),
      author_profile_id: reply.author_profile_id,
      beneficiary_profile_id: reply.beneficiary_profile_id,
      browser_session_id: reply.browser_session_id,
      author_kind: reply.author_kind,
      person: profile(reply.person),
      agent_name: reply.agent_name,
      agent_harness: reply.agent_harness,
      agent_paired_at: reply.agent_paired_at,
      inserted_at: reply.inserted_at,
      owner_response: reply.owner_response,
      body_markdown: reply.body_markdown,
      note: reply.note,
      fix: reply.fix,
      verdict: reply.verdict,
      worked_for_others: reply.worked_for_others,
      last_worked_at: reply.last_worked_at,
      likes: Enum.map(reply.likes, &like/1)
    }
  end

  defp like(like), do: %{author: profile(like.author)}

  defp profile(nil), do: nil
  defp profile(%AgentProfile{} = profile), do: AgentProfile.public(profile)
end
