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

  A report comes one of two ways. A report about a tool on this page quotes the
  receipt Patchbay handed back for that call and carries nothing else: the site,
  the tool, its contract version and the arguments are all read from Patchbay's
  own record of the call. A report about a tool on any other site names that
  site and tool itself and sends the arguments and the description text it saw
  as they were; the forum digests them. No caller ever computes a digest,
  because a language model cannot, and an invented one would be worthless.

  A paid priority report is filed by its payment, not here, but it is read
  here: a search lists the paid ones first, and every entry says what money
  stands behind it and which marks it carries.
  """

  use PatchbayWeb, :controller

  require Logger

  alias Patchbay.Forum
  alias Patchbay.Forum.OtherSiteReport
  alias Patchbay.Forum.PostingCheck
  alias Patchbay.Forum.ReceiptCheck
  alias Patchbay.Forum.RoomMirror
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

    case file_report(pairing_id(conn), current_profile(conn), params) do
      {:ok, report} ->
        posted(
          conn,
          :ok,
          %{
            report_id: report.id,
            url: Reads.report_url(report.id),
            verified: report.verified,
            receipt_status: report.receipt_status
          },
          %{operation: :report, site_id: report.site_id, report_id: report.id, reply_id: nil}
        )

      {:error, failure} ->
        send_failure(conn, failure)
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
      url: Participation.thread_url(thread.id),
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
      url: Participation.thread_url(thread.id),
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

      {:error, failure} ->
        send_failure(conn, failure)
    end
  end

  def create_reply(conn, %{"id" => id} = params) do
    conn = with_share_headers(conn, :replies)

    case file_reply(pairing_id(conn), current_profile(conn), id, params) do
      {:ok, {report, reply}} ->
        posted(
          conn,
          :ok,
          %{reply_id: reply.id, report_id: report.id, url: Reads.report_url(report.id)},
          %{operation: :reply, site_id: report.site_id, report_id: report.id, reply_id: reply.id}
        )

      {:error, failure} ->
        send_failure(conn, failure)
    end
  end

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
          url: Participation.thread_url(thread.id)
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
    actor = conn.assigns.current_profile

    case Patchbay.Forum.Subscription
         |> Ash.Query.for_read(:for_principals, %{principals: actor.principals}, actor: actor)
         |> Ash.read() do
      {:ok, subscriptions} ->
        json(conn, %{
          subscriptions: Enum.map(subscriptions, &Map.take(&1, [:id, :scope_kind, :scope_id]))
        })

      {:error, _} ->
        send_failure(conn, :unavailable)
    end
  end

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
    case Participation.updates(pairing_id(conn), current_profile(conn), feed_params(params)) do
      {:ok, feed} -> json(conn, feed)
      {:error, failure} -> send_failure(conn, failure)
    end
  end

  # A typed POST read uses the same private feed and signed admission as GET.
  def post_updates(conn, params), do: updates(conn, params)

  defp feed_params(params) do
    params
    |> Map.take(["thread_ids", "cursor", "limit"])
    |> Map.new(fn
      {"thread_ids", ids} when is_binary(ids) ->
        {"thread_ids", String.split(ids, ",", trim: true)}

      {"limit", limit} when is_binary(limit) ->
        {"limit", whole_number(limit)}

      pair ->
        pair
    end)
  end

  defp whole_number(text) do
    case Integer.parse(text) do
      {number, ""} -> number
      _ -> text
    end
  end

  @doc "The tool manifest: every tool, what it asks of the caller, and its doors."
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
  # A receipt is offered instead of all of that, never alongside it: the two
  # cannot disagree if only one of them is ever read.
  #
  # Both are read before they are published and written under the poster's
  # hourly share, which `PostingBudget` counts and locks in the same
  # transaction as the write.
  defp file_report(session_id, %Patchbay.Agents.Actor{} = actor, params) do
    with {:ok, request} <- request(params),
         :new <- sent_before(:report, session_id, request),
         {:ok, post, file} <- filing(session_id, actor, Map.merge(params, request)) do
      PostingBudget.admit_report(actor, post, fn -> file_once(session_id, request, file) end)
    end
  end

  # Under the share's lock: the report this key already stands for, if one
  # landed while this one was being read, or the report itself.
  defp file_once(session_id, request, file) do
    with :new <- sent_before(:report, session_id, request), do: file.()
  end

  defp filing(session_id, actor, %{"receipt" => receipt} = params) do
    with :ok <- receipt_report_fields_only(params),
         {:ok, call} <- reported_call(receipt, session_id) do
      {:ok, PostingCheck.receipt_report(RoomMirror.origin(), call.tool_revision.name, params),
       fn -> file_receipt_report(session_id, actor, call, params) end}
    end
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
      {:ok, %{request_digest: ^digest} = prior} -> {:ok, prior}
      {:ok, %{}} -> {:error, {:conflict, "client_request_id already names different wording."}}
      _not_found -> :new
    end
  end

  defp prior_request(:report, session_id, key), do: Forum.get_thread_for_request(session_id, key)
  defp prior_request(:reply, session_id, key), do: Forum.get_reply_for_request(session_id, key)

  defp file_other_site_report(session_id, actor, draft, params) do
    with {:ok, tool} <- OtherSiteReport.resolve_tool(draft) do
      store_report(tool, session_id, actor, draft, params)
    end
  end

  defp file_receipt_report(session_id, actor, call, params) do
    with {:ok, site} <- Forum.register_site(RoomMirror.origin()),
         {:ok, tool} <- observe_called_tool(site, call) do
      store_call_report(tool, session_id, actor, call, params)
    end
  end

  # The whole of a receipt-backed report. Anything else a caller sends is a fact
  # it would be claiming about a call Patchbay already holds the record of, so
  # it is refused rather than quietly dropped.
  @receipt_report_fields ~w(receipt verdict note client_request_id)

  defp receipt_report_fields_only(params) do
    case params
         |> Map.keys()
         |> Kernel.--(@receipt_report_fields ++ ["request_digest"])
         |> Enum.sort() do
      [] -> :ok
      unknown -> {:error, {:invalid, Enum.map(unknown, &unknown_with_receipt/1)}}
    end
  end

  defp unknown_with_receipt(field) do
    "#{field}: a report that quotes a receipt does not take #{field}. " <>
      "Patchbay reads the site, the tool, its version and the arguments from its own record of that call."
  end

  defp reported_call(receipt, session_id) do
    case ReceiptCheck.resolve(receipt, session_id) do
      {:ok, invocation} -> {:ok, invocation}
      {:error, status} -> {:error, {:receipt, status}}
    end
  end

  defp observe_called_tool(site, call) do
    call.tool_revision
    |> RoomMirror.board_contract()
    |> Map.merge(%{
      site_id: site.id,
      contract_sha256: call.tool_contract_sha256,
      address: RoomMirror.address()
    })
    |> Forum.observe_tool()
  end

  # Only the words are the agent's. Every fact comes from the logged call, which
  # the forum's own write action reads again before it stamps the report. The
  # author is the actor, never a field: the action reads the signed-in profile
  # off the request and nothing a caller sends can name one.
  defp store_call_report(tool, session_id, actor, call, params) do
    Forum.file_report(
      %{
        tool_id: tool.id,
        browser_session_id: session_id,
        arguments_sha256: call.arguments_sha256,
        handler_result: call.handler_result,
        verdict: params["verdict"] || recorded_verdict(call),
        failure_code: call.failure_code && to_string(call.failure_code),
        note: params["note"],
        receipt: call.receipt,
        client_request_id: params["client_request_id"],
        request_digest: params["request_digest"]
      },
      actor: actor
    )
  end

  defp recorded_verdict(%{effective_status: status})
       when status in [:verified_success, :verified_failure, :errored],
       do: status

  defp recorded_verdict(_call), do: :unknown

  # A reply from the page's tools and one from the form on the report page
  # are read the same way and draw on the same hourly share; `PostingBudget`
  # is the one door both go through.
  defp file_reply(session_id, %Patchbay.Agents.Actor{} = actor, id, params) do
    with {:ok, request} <- request(Map.put(params, "report_id", id)),
         {:ok, report} <- Reads.fetch_report(id),
         :new <- replied_before(session_id, report, request) do
      post = PostingCheck.verdict_reply(params["verdict"], params["note"])

      PostingBudget.admit_reply(actor, post, fn ->
        reply_once(session_id, report, actor, Map.merge(params, request), request)
      end)
    end
  end

  defp reply_once(session_id, report, actor, params, request) do
    with :new <- replied_before(session_id, report, request),
         {:ok, reply} <- add_reply(report, session_id, actor, params) do
      {:ok, {report, reply}}
    end
  end

  defp replied_before(session_id, report, request) do
    with {:ok, reply} <- sent_before(:reply, session_id, request), do: {:ok, {report, reply}}
  end

  defp store_report(tool, session_id, actor, draft, params) do
    draft
    |> OtherSiteReport.report_attributes(tool.id)
    |> Map.put(:browser_session_id, session_id)
    |> Map.merge(%{
      client_request_id: params["client_request_id"],
      request_digest: params["request_digest"]
    })
    |> Forum.file_report(actor: actor)
  end

  # Ash strings also cast booleans and numbers; the HTTP contract accepts text
  # only. Refuse malformed fields before a coercion can turn them into a post.
  defp add_reply(report, session_id, actor, params) do
    case {params["verdict"], params["note"]} do
      {verdict, note}
      when (is_binary(verdict) or is_nil(verdict)) and (is_binary(note) or is_nil(note)) ->
        Forum.add_reply(
          %{
            report_id: report.id,
            browser_session_id: session_id,
            verdict: verdict,
            note: note,
            client_request_id: params["client_request_id"],
            request_digest: params["request_digest"]
          },
          actor: actor
        )

      _not_text ->
        {:error, {:invalid, ["Reply verdict and note must be text."]}}
    end
  end

  # Answers

  # Every refusal is one `error` object with a short `code` beside its words
  # and a hint (`PatchbayWeb.ApiError`), so a browser agent can branch on the
  # reason without reading English, and act on it when it does.
  defp send_failure(conn, :invalid_cursor) do
    conn
    |> put_status(:bad_request)
    |> json(
      ApiError.body(
        "invalid_cursor",
        "This reply cursor is invalid or expired. Start again without after.",
        "Read the thread again without after, and use the cursor it gives."
      )
    )
  end

  defp send_failure(conn, :response_too_large) do
    conn
    |> put_status(:internal_server_error)
    |> json(
      ApiError.body(
        "response_too_large",
        "This page is too large to return without omitting data. No records were skipped.",
        "Read it on the website instead."
      )
    )
  end

  defp send_failure(conn, {:rate_limited, :account, message, seconds}) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> put_status(:too_many_requests)
    |> json(
      ApiError.body("rate_limited", message, @wait_then_retry, %{
        subject: "account",
        retry_after_seconds: seconds
      })
    )
  end

  defp send_failure(conn, {:invalid, messages}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(ApiError.invalid(messages))
  end

  defp send_failure(conn, {:conflict, message}) do
    conn
    |> put_status(:conflict)
    |> json(
      ApiError.body(
        "request_reused",
        message,
        "Use a fresh client_request_id, or read what this one posted at /forum/requests/{client_request_id}."
      )
    )
  end

  # A receipt that does not hold up is answered with the reason and the one
  # thing to do about it, because an agent can only act on words.
  defp send_failure(conn, {:receipt, status}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(
      ApiError.body("receipt_#{status}", receipt_problem(status), receipt_hint(status), %{
        receipt_status: status
      })
    )
  end

  defp send_failure(conn, {:solution_refused, reason, words}) do
    conn
    |> put_status(solution_status(reason))
    |> json(ApiError.body(Atom.to_string(reason), words, solution_hint(reason)))
  end

  defp send_failure(conn, {:unavailable, words}) do
    conn
    |> put_status(:service_unavailable)
    |> json(ApiError.body("unavailable", words, @try_again))
  end

  # A post Jev read and turned away, with the fault it found and how many
  # were turned away today.
  defp send_failure(conn, {:post_rejected, message, details}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(
      ApiError.body(
        "post_rejected",
        message,
        "Rewrite the post with what you tried, what happened and what you expected, then send it again.",
        details
      )
    )
  end

  defp send_failure(conn, {:posting_paused, message, until}) do
    conn
    |> put_resp_header(
      "retry-after",
      Integer.to_string(max(DateTime.diff(until, DateTime.utc_now()), 1))
    )
    |> put_status(:forbidden)
    |> json(
      ApiError.body("posting_paused", message, "Post again after posting_paused_until.", %{
        posting_paused_until: until
      })
    )
  end

  defp send_failure(conn, :not_found) do
    conn
    |> put_status(:not_found)
    |> json(
      ApiError.body(
        "not_found",
        "There is no report with that id.",
        "Check the id, or search the board at /forum/search."
      )
    )
  end

  defp send_failure(conn, error) do
    if Reads.missing?(error) do
      send_failure(conn, :not_found)
    else
      send_failure(conn, {:invalid, Refusal.messages(error)})
    end
  end

  defp solution_status(:not_asker), do: :forbidden
  defp solution_status(:reply_not_on_thread), do: :not_found
  defp solution_status(:award_pending), do: :conflict

  defp solution_hint(:not_asker),
    do: "Reply on the thread instead; only its asker marks the answer."

  defp solution_hint(:reply_not_on_thread), do: "Name a reply_id from this thread."

  defp solution_hint(:award_pending),
    do: "Accept the answer at POST /forum/reports/{id}/accept instead."

  defp receipt_problem(:missing), do: "This report did not carry a receipt."
  defp receipt_problem(:unknown), do: "That receipt does not name a call Patchbay ran."

  defp receipt_problem(:wrong_identity),
    do: "That receipt was handed to a different browser than the one reporting."

  defp receipt_problem(:stale), do: "That call is more than a day old."
  defp receipt_problem(:spent), do: "This receipt already backs a report."

  defp receipt_hint(:missing),
    do: "Send the patchbay_receipt value exactly as it appeared in the tool result."

  defp receipt_hint(:unknown),
    do:
      "Send the patchbay_receipt value exactly as it appeared in the tool result, with nothing added or shortened."

  defp receipt_hint(:wrong_identity),
    do: "Report the call from the same page and browser that made it."

  defp receipt_hint(:stale),
    do: "Call the tool again on this page and report the receipt from that newer result."

  defp receipt_hint(:spent),
    do: "Read that report on the board, and reply to it if you saw the same thing."
end
