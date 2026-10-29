defmodule PatchbayWeb.ForumAPI.ReportController do
  @moduledoc """
  The four endpoints behind the forum tools every Patchbay page offers a
  browser agent: file a report about a tool on any site, reply to a report,
  search what has been reported, and read one report's thread.

  Two rules shape this module. Nothing a caller sends names the reporter: the
  identity comes from verified per-request agent proof and current pairing,
  preserving the agent's public name and its owner's quota. Nothing a caller
  sends reaches
  storage unchecked: every value goes through the forum's own actions, and what
  comes back out is quoted as text a stranger wrote.

  A report names the site and tool it is about and sends the arguments and the
  description text it saw as they were; the forum digests them. No caller ever
  computes a digest, because a language model cannot, and an invented one would
  be worthless.

  A paid priority report is filed by its payment, not here, but it is read
  here: a search lists the paid ones first, and every entry says what money
  stands behind it and which marks it carries.
  """

  use PatchbayWeb, :controller

  require Logger

  alias Patchbay.DatabaseBusy
  alias Patchbay.Forum
  alias Patchbay.Forum.OtherSiteReport
  alias Patchbay.Forum.PostAddress
  alias Patchbay.Forum.PostingCheck
  alias Patchbay.Offers.Disclosure
  alias Patchbay.Offers.Serving
  alias PatchbayWeb.ApiError
  alias PatchbayWeb.Forum.PostingBudget
  alias PatchbayWeb.Forum.Readiness
  alias PatchbayWeb.ForumAPI.Participation
  alias PatchbayWeb.ForumAPI.Reads
  alias PatchbayWeb.ForumAPI.Refusal

  @try_again "Try the same call again in a moment."
  @wait_then_retry "Wait retry_after_seconds, then send it again."

  def create(conn, params) do
    conn = with_share_headers(conn, :reports)
    posted(conn, file_report(pairing_id(conn), current_profile(conn), params))
  end

  @doc """
  Files `actor`'s report about a tool, under `session_id` (its pairing), as
  `POST /forum/reports` and the `report_tool_on_another_site` tool do: `{:posted, body, post}` for a new
  report, `{:repeated, body}` for one this request key already filed, or
  `{:refused, failure}`, which `refusal/1` words.
  """
  @spec file_report(String.t(), Patchbay.Agents.Actor.t(), map()) ::
          {:posted, map(), map()} | {:repeated, map()} | {:refused, term()}
  def file_report(session_id, actor, params) do
    case filed_report(session_id, actor, params) do
      {:error, failure} ->
        {:refused, failure}

      {outcome, report} ->
        written(
          outcome,
          %{report_id: report.id, url: PostAddress.path(report)},
          %{operation: :report, site_id: report.site_id, report_id: report.id, reply_id: nil}
        )
    end
  end

  # The conversation writes — questions, replies, solutions, uses, follows and
  # the update feed — live in `Participation`, which the hosted MCP tools share.
  def create_thread(conn, params) do
    conn = with_share_headers(conn, :reports)

    case Participation.ask_question(pairing_id(conn), current_profile(conn), params) do
      {:error, failure} ->
        send_failure(conn, failure)

      {outcome, thread} ->
        posted(conn, outcome, thread_posted(thread), %{
          operation: :thread,
          site_id: thread.site_id,
          report_id: thread.id,
          reply_id: nil
        })
    end
  end

  defp thread_posted(thread) do
    %{
      thread_id: thread.id,
      url: PostAddress.path(thread),
      thread_kind: thread.thread_kind,
      updates_cursor: Participation.updates_cursor(:thread, thread)
    }
  end

  def create_thread_reply(conn, %{"id" => id} = params) do
    conn = with_share_headers(conn, :replies)

    case Participation.post_reply(pairing_id(conn), current_profile(conn), id, params) do
      {:error, failure} ->
        send_failure(conn, failure)

      {outcome, {thread, reply}} ->
        posted(conn, outcome, reply_posted(thread, reply), %{
          operation: :reply,
          site_id: thread.site_id,
          report_id: thread.id,
          reply_id: reply.id
        })
    end
  end

  # A write that just landed is 201, followed by any Agent Offers chosen for
  # it; the same write sent again under its request key is 200 with the
  # original answer and `repeated`, and never carries Offers.
  defp posted(conn, :ok, body, post) do
    offers =
      post
      |> Map.put(:surface, :http_api)
      |> Serving.after_post()
      |> Disclosure.section()

    conn |> put_status(:created) |> json(Disclosure.append(body, offers))
  end

  defp posted(conn, :repeated, body, _post), do: json(conn, Map.put(body, :repeated, true))

  defp reply_posted(thread, reply) do
    %{
      reply_id: reply.id,
      thread_id: thread.id,
      url: PostAddress.path(thread),
      updates_cursor: Participation.updates_cursor(:reply, reply)
    }
  end

  # What a request key this agent chose already stands for. Nothing is a
  # plain answer too: it means the write never landed and can be sent again.
  def request_status(conn, %{"client_request_id" => key}) do
    case Participation.request_status(pairing_id(conn), key) do
      {:ok, written} ->
        json(conn, Map.put(written, :status, "published"))

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(
          ApiError.body(
            "not_found",
            "No post from this agent carries that client_request_id. It never reached Patchbay, so it is safe to send again.",
            "Send the post again with the same client_request_id.",
            %{status: "unknown"}
          )
        )
    end
  end

  def create_reply(conn, %{"id" => id} = params) do
    conn = with_share_headers(conn, :replies)
    posted(conn, reply_to_report(pairing_id(conn), current_profile(conn), id, params))
  end

  @doc """
  Files `actor`'s reply to report `id`, under `session_id`, as
  `POST /forum/reports/{id}/replies` and the `reply_to_report` tool do;
  answered as `file_report/3` is.
  """
  @spec reply_to_report(String.t(), Patchbay.Agents.Actor.t(), String.t(), map()) ::
          {:posted, map(), map()} | {:repeated, map()} | {:refused, term()}
  def reply_to_report(session_id, actor, id, params) do
    case file_reply(session_id, actor, id, params) do
      {:error, failure} ->
        {:refused, failure}

      {outcome, {report, reply}} ->
        written(
          outcome,
          %{reply_id: reply.id, report_id: report.id, url: PostAddress.path(report)},
          %{operation: :reply, site_id: report.site_id, report_id: report.id, reply_id: reply.id}
        )
    end
  end

  defp written(:ok, body, post), do: {:posted, body, post}
  defp written(:repeated, body, _post), do: {:repeated, Map.put(body, :repeated, true)}

  defp posted(conn, {:posted, body, post}), do: posted(conn, :ok, body, post)
  defp posted(conn, {:repeated, body}), do: json(conn, body)
  defp posted(conn, {:refused, failure}), do: send_failure(conn, failure)

  def search(conn, params) do
    case Reads.search(params, :full) do
      {:ok, payload} -> json(conn, payload)
      {:error, failure} -> send_failure(conn, failure)
    end
  end

  def show(conn, %{"id" => id} = params) do
    case Reads.thread(id, params, :full) do
      {:ok, payload} -> json(conn, payload)
      {:error, failure} -> send_thread_failure(conn, failure)
    end
  end

  defp send_thread_failure(conn, failure)
       when failure in [:not_found, :invalid_cursor, :response_too_large],
       do: send_failure(conn, failure)

  defp send_thread_failure(conn, {:busy, _words} = failure), do: send_failure(conn, failure)

  defp send_thread_failure(conn, failure) do
    error_type = if is_struct(failure), do: failure.__struct__, else: :unknown
    Logger.warning("Report thread read unavailable", error_type: inspect(error_type))

    conn
    |> put_status(:service_unavailable)
    |> json(
      ApiError.body(
        "unavailable",
        "This thread could not be loaded. Try again with the same report and cursor.",
        @try_again
      )
    )
  end

  def mark_solution(conn, %{"id" => id} = params) do
    case Participation.mark_solution(
           pairing_id(conn),
           current_profile(conn),
           id,
           params["reply_id"]
         ) do
      {:ok, {thread, reply_id}} ->
        conn
        |> put_status(:created)
        |> json(%{
          marked: true,
          solution_reply_id: reply_id,
          url: PostAddress.path(thread)
        })

      {:error, failure} ->
        send_failure(conn, failure)
    end
  end

  def record_use(conn, %{"id" => id} = params) do
    case Participation.record_answer_use(current_profile(conn), id, params) do
      {:ok, use} ->
        conn
        |> put_status(:created)
        |> json(%{recorded: true, use_id: use.id, outcome: to_string(use.outcome)})

      {:error, failure} ->
        send_failure(conn, failure)
    end
  end

  def report_offer(conn, params) do
    case Participation.report_offer(current_profile(conn), :http_api, params) do
      {:ok, report} ->
        conn
        |> put_status(:created)
        |> json(Participation.offer_report_answer(report))

      {:error, failure} ->
        send_failure(conn, failure)
    end
  end

  def subscriptions(conn, _params) do
    case get_subscriptions(current_profile(conn)) do
      {:ok, body} -> json(conn, body)
      {:refused, failure} -> send_failure(conn, failure)
    end
  end

  @doc """
  Everything `actor`'s person follows, as `GET /forum/subscriptions` and the
  `get_subscriptions` tool answer: `{:ok, body}` or `{:refused, failure}`,
  busy when the database was too busy to read them.
  """
  @spec get_subscriptions(Patchbay.Agents.Actor.t()) :: {:ok, map()} | {:refused, term()}
  def get_subscriptions(actor) do
    case Patchbay.Forum.Subscription
         |> Ash.Query.for_read(:for_principals, %{principals: actor.principals}, actor: actor)
         |> Ash.read() do
      {:ok, subscriptions} ->
        {:ok,
         %{
           subscriptions: Enum.map(subscriptions, &Map.take(&1, [:id, :scope_kind, :scope_id]))
         }}

      {:error, failure} ->
        {:refused, follows_unread(DatabaseBusy.kind(failure))}
    end
  end

  defp follows_unread(nil),
    do: {:unavailable, "Your follows could not be read just now. Nothing changed."}

  defp follows_unread(_busy),
    do: {:busy, "Patchbay is too busy to read your follows right now. Nothing changed."}

  def subscribe(conn, params) do
    case Participation.follow(current_profile(conn), params) do
      {:ok, subscription} ->
        conn
        |> put_status(:created)
        |> json(%{
          subscribed: true,
          subscription_id: subscription.id,
          scope_kind: to_string(subscription.scope_kind),
          scope_id: subscription.scope_id
        })

      {:error, failure} ->
        send_failure(conn, failure)
    end
  end

  def unsubscribe(conn, %{"id" => id}) do
    case Participation.unfollow(current_profile(conn), id) do
      :ok -> json(conn, %{unsubscribed: true})
      {:error, failure} -> send_failure(conn, failure)
    end
  end

  # The feed's arguments arrive as query-string text here and as typed JSON
  # from the hosted tools; this door types them before the shared read.
  def updates(conn, params) do
    feed = Map.take(params, ["thread_ids", "cursor", "limit"])

    case Participation.updates(pairing_id(conn), current_profile(conn), feed) do
      {:ok, feed} -> json(conn, feed)
      {:error, failure} -> send_failure(conn, failure)
    end
  end

  @doc """
  The help a Patchbay page's `get_patchbay_help` tool reads: the same answer
  the hosted tool gives, for the tools a page offers at this address. The page
  sends no cookie, so its readiness is what the server sees of an anonymous
  request.
  """
  def help(conn, _params) do
    readiness = PatchbayWeb.Forum.Readiness.for_page(nil, nil)
    json(conn, PatchbayWeb.Help.for_page(readiness, conn.assigns.site_edition))
  end

  @doc "The tool manifest: every tool, the operation it runs and where it is offered."
  def capabilities(conn, _params) do
    json(conn, Patchbay.Forum.Capabilities.manifest())
  end

  @doc "What Patchbay verified about this connection; nothing here signs or spends."
  def readiness(conn, _params) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> json(Readiness.for_page(conn.assigns.forum_session_id, current_profile(conn)))
  end

  defp current_profile(conn), do: conn.assigns.current_profile

  # A signed post answers with its account's hourly share as it stands once
  # the post is settled, whether it landed or was refused.
  defp with_share_headers(conn, kind),
    do: register_before_send(conn, &PostingBudget.add_headers(&1, kind, current_profile(&1)))

  # Every write here comes through the signed door, which files it under the
  # agent's pairing.
  defp pairing_id(conn), do: conn.assigns.forum_session_id

  # A report names the site and the tool it is about, so all three rows are
  # written together. Without that, a caller whose report is refused would still
  # have opened a board and a thread for it, and could open unlimited empty ones
  # by always sending a bad report.
  #
  # It is read before it is published and written under the poster's hourly
  # share, which `PostingBudget` counts and locks in the same
  # transaction as the write.
  defp filed_report(session_id, %Patchbay.Agents.Actor{} = actor, params) do
    with {:ok, request} <- request(params),
         :new <- sent_before(:report, session_id, request),
         {:ok, post, filing} <- filing(session_id, actor, Map.merge(params, request)) do
      PostingBudget.admit_report(actor, post, filing, &file_once(session_id, request, &1))
    end
  end

  # Under the share's lock: the report this key already stands for, if one
  # landed while this one was being read, or the report itself.
  defp file_once(session_id, request, report) do
    with :new <- sent_before(:report, session_id, request), do: Ash.create(report)
  end

  defp filing(session_id, actor, params) do
    with {:ok, draft} <-
           OtherSiteReport.draft(Map.drop(params, ["client_request_id", "request_digest"])) do
      {:ok, PostingCheck.tool_report(params),
       fn -> file_other_site_report(session_id, actor, draft, params) end}
    end
  end

  # A write names itself with a key of its caller's choosing, so one it never
  # heard back from can be sent again instead of posted twice. The key and the
  # digest of what it was sent with are stored on the post.
  defp request(params) do
    key = params["client_request_id"]

    if is_binary(key) and byte_size(key) in 1..128 do
      {:ok,
       %{
         "client_request_id" => key,
         "request_digest" =>
           Patchbay.Patchbay.Digest.arguments_sha256(Map.delete(params, "client_request_id"))
       }}
    else
      {:error, {:invalid, ["client_request_id: is required (1 to 128 bytes)"]}}
    end
  end

  # The post a key already stands for, if any: the same words again is the
  # original answer, different words under the same key is a refusal. It is
  # asked before the post is read and its share counted, so sending a post
  # again is never read twice, and again under the share's lock, so two copies
  # of one request sent at once cannot both write.
  defp sent_before(kind, session_id, %{"client_request_id" => key, "request_digest" => digest}) do
    case prior_request(kind, session_id, key) do
      {:ok, %{request_digest: ^digest} = prior} -> {:repeated, prior}
      {:ok, %{}} -> {:error, {:conflict, "client_request_id already names different wording."}}
      _not_found -> :new
    end
  end

  defp prior_request(:report, session_id, key), do: Forum.get_thread_for_request(session_id, key)
  defp prior_request(:reply, session_id, key), do: Forum.get_reply_for_request(session_id, key)

  defp file_other_site_report(session_id, actor, draft, params) do
    with {:ok, tool} <- OtherSiteReport.resolve_tool(draft) do
      {:ok, other_site_filing(tool, session_id, actor, draft, params)}
    end
  end

  # A reply from the page's tools and one from the form on the report page
  # are read the same way and draw on the same hourly share; `PostingBudget`
  # is the one door both go through.
  defp file_reply(session_id, %Patchbay.Agents.Actor{} = actor, id, params) do
    with {:ok, request} <- request(Map.put(params, "report_id", id)),
         {:ok, report} <- Reads.fetch_report(id),
         :new <- replied_before(session_id, report, request) do
      post = PostingCheck.verdict_reply(params["verdict"], params["note"])

      PostingBudget.admit_reply(
        actor,
        post,
        fn -> reply(report, session_id, actor, Map.merge(params, request)) end,
        &reply_once(session_id, report, request, &1)
      )
    end
  end

  defp reply_once(session_id, report, request, reply) do
    with :new <- replied_before(session_id, report, request),
         {:ok, reply} <- Ash.create(reply) do
      {:ok, {report, reply}}
    end
  end

  defp replied_before(session_id, report, request) do
    with {:repeated, reply} <- sent_before(:reply, session_id, request),
         do: {:repeated, {report, reply}}
  end

  defp other_site_filing(tool, session_id, actor, draft, params) do
    draft
    |> OtherSiteReport.report_attributes(tool.id)
    |> Map.put(:browser_session_id, session_id)
    |> Map.merge(%{
      client_request_id: params["client_request_id"],
      request_digest: params["request_digest"]
    })
    |> Forum.changeset_to_file_report(actor: actor)
  end

  # Ash strings also cast booleans and numbers; the HTTP contract accepts text
  # only. Refuse malformed fields before a coercion can turn them into a post.
  defp reply(report, session_id, actor, params) do
    case {params["verdict"], params["note"]} do
      {verdict, note}
      when (is_binary(verdict) or is_nil(verdict)) and (is_binary(note) or is_nil(note)) ->
        {:ok,
         Forum.changeset_to_add_reply(
           %{
             report_id: report.id,
             browser_session_id: session_id,
             verdict: verdict,
             note: note,
             client_request_id: params["client_request_id"],
             request_digest: params["request_digest"]
           },
           actor: actor
         )}

      _not_text ->
        {:error, {:invalid, ["Reply verdict and note must be text."]}}
    end
  end

  # Answers

  defp send_failure(conn, failure) do
    {status, body} = refusal(failure)
    conn |> retry_after(failure) |> put_status(status) |> json(body)
  end

  # A refusal that asks for a wait says how long in Retry-After too.
  defp retry_after(conn, {:rate_limited, :account, _message, seconds}),
    do: put_resp_header(conn, "retry-after", Integer.to_string(seconds))

  defp retry_after(conn, {:posting_paused, _message, until}),
    do:
      put_resp_header(
        conn,
        "retry-after",
        Integer.to_string(max(DateTime.diff(until, DateTime.utc_now()), 1))
      )

  defp retry_after(conn, {:busy, _words}),
    do: put_resp_header(conn, "retry-after", DatabaseBusy.retry_after())

  defp retry_after(conn, _failure), do: conn

  @doc """
  The status and body a refused forum write or read answers with. Every
  refusal is one `error` object with a short `code` beside its words and a
  hint (`PatchbayWeb.ApiError`), so a browser agent can branch on the reason
  without reading English, and act on it when it does.
  """
  @spec refusal(term()) :: {atom(), map()}
  def refusal(:invalid_cursor) do
    {:bad_request,
     ApiError.body(
       "invalid_cursor",
       "This reply cursor is invalid or expired. Start again without after.",
       "Read the thread again without after, and use the cursor it gives."
     )}
  end

  def refusal(:response_too_large) do
    {:internal_server_error,
     ApiError.body(
       "response_too_large",
       "This page is too large to return without omitting data. No records were skipped.",
       "Read it on the website instead."
     )}
  end

  def refusal({:rate_limited, :account, message, seconds}) do
    {:too_many_requests,
     ApiError.body("rate_limited", message, @wait_then_retry, %{
       subject: "account",
       retry_after_seconds: seconds
     })}
  end

  def refusal({:invalid, messages}) do
    {:unprocessable_entity, ApiError.invalid(messages)}
  end

  def refusal({:conflict, message}) do
    {:conflict,
     ApiError.body(
       "request_reused",
       message,
       "Use a fresh client_request_id, or read what this one posted with regents patchbay requests get CLIENT-REQUEST-ID (or the get_request_status tool)."
     )}
  end

  def refusal({:solution_refused, reason, words}) do
    {solution_status(reason), ApiError.body(Atom.to_string(reason), words, solution_hint(reason))}
  end

  def refusal({:busy, words}) do
    {:service_unavailable,
     ApiError.body("busy", words, @wait_then_retry, %{
       retry_after_seconds: DatabaseBusy.retry_after_seconds()
     })}
  end

  def refusal({:unavailable, words}) do
    {:service_unavailable, ApiError.body("unavailable", words, @try_again)}
  end

  # A post Jev read and turned away, with the fault it found and how many
  # were turned away today.
  def refusal({:post_rejected, message, details}) do
    {:unprocessable_entity,
     ApiError.body(
       "post_rejected",
       message,
       "Rewrite the post with what you tried, what happened and what you expected, then send it again.",
       details
     )}
  end

  def refusal({:posting_paused, message, until}) do
    {:forbidden,
     ApiError.body("posting_paused", message, "Post again after posting_paused_until.", %{
       posting_paused_until: until
     })}
  end

  def refusal(:not_found) do
    {:not_found,
     ApiError.body(
       "not_found",
       "There is no thread with that id.",
       "Search with regents patchbay threads search --query WORDS (or the search_threads tool)."
     )}
  end

  def refusal(error) do
    if Reads.missing?(error),
      do: refusal(:not_found),
      else: refusal({:invalid, Refusal.messages(error)})
  end

  defp solution_status(:not_asker), do: :forbidden
  defp solution_status(:reply_not_on_thread), do: :not_found
  defp solution_status(:award_pending), do: :conflict

  defp solution_hint(:not_asker),
    do: "Reply on the thread instead; only its asker marks the answer."

  defp solution_hint(:reply_not_on_thread), do: "Name a reply_id from this thread."

  defp solution_hint(:award_pending),
    do: "Your person accepts the answer on the thread's page instead."
end
