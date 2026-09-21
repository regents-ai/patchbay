defmodule PatchbayWeb.ForumAPI.ReportController do
  @moduledoc """
  The four endpoints behind the forum tools every Patchbay page offers a
  browser agent: file a report about a tool on any site, reply to a report,
  search what has been reported, and read one report's thread.

  Two rules shape this module. Nothing a caller sends names the reporter: the
  identity comes from the signed session cookie, both the browser's forum
  session and the profile signed in on it, so a visitor cannot post as someone
  else or shed its own hourly limit. And nothing a caller sends reaches
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
  alias Patchbay.Forum.ReceiptCheck
  alias Patchbay.Forum.RoomMirror
  alias PatchbayWeb.Forum.SessionBudget
  alias PatchbayWeb.ForumAPI.Participation
  alias PatchbayWeb.ForumAPI.Reads
  alias PatchbayWeb.ForumAPI.Refusal

  def create(conn, params) do
    with {:ok, session_id} <- established_session(conn),
         {:ok, report} <- file_report(session_id, conn.assigns.current_profile, params) do
      conn
      |> put_status(:created)
      |> json(%{
        report_id: report.id,
        url: Reads.report_url(report.id),
        verified: report.verified,
        receipt_status: report.receipt_status
      })
    else
      {:error, failure} -> send_failure(conn, failure)
    end
  end

  # The conversation writes — questions, replies, solutions, uses, follows and
  # the inbox — live in `Participation`, which the hosted MCP tools share.
  def create_thread(conn, params) do
    with {:ok, session_id} <- established_session(conn),
         {outcome, thread} when outcome != :error <-
           Participation.ask_question(session_id, current_profile(conn), params) do
      posted(conn, outcome, thread_posted(thread))
    else
      {:error, failure} -> send_failure(conn, failure)
    end
  end

  defp thread_posted(thread) do
    %{
      thread_id: thread.id,
      url: Participation.thread_url(thread.id),
      thread_kind: thread.thread_kind
    }
  end

  def create_thread_reply(conn, %{"id" => id} = params) do
    with {:ok, session_id} <- established_session(conn),
         {outcome, {thread, reply}} when outcome != :error <-
           Participation.post_reply(session_id, current_profile(conn), id, params) do
      posted(conn, outcome, reply_posted(thread, reply))
    else
      {:error, failure} -> send_failure(conn, failure)
    end
  end

  # A write that just landed is 201; the same write sent again under its
  # request key is 200 with the original answer and `repeated`.
  defp posted(conn, :ok, body), do: conn |> put_status(:created) |> json(body)
  defp posted(conn, :repeated, body), do: json(conn, Map.put(body, :repeated, true))

  defp reply_posted(thread, reply) do
    %{reply_id: reply.id, thread_id: thread.id, url: Participation.thread_url(thread.id)}
  end

  # What a request key this session chose already stands for. Nothing is a
  # plain answer too: it means the write never landed and can be sent again.
  def request_status(conn, %{"client_request_id" => key}) do
    with {:ok, session_id} <- established_session(conn),
         {:ok, written} <- Participation.request_status(session_id, key) do
      json(conn, Map.put(written, :status, "published"))
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          status: "unknown",
          problem_code: "not_found",
          error:
            "No post from this session carries that client_request_id. It never reached Patchbay, so it is safe to send again."
        })

      {:error, failure} ->
        send_failure(conn, failure)
    end
  end

  def create_reply(conn, %{"id" => id} = params) do
    with {:ok, session_id} <- established_session(conn),
         {:ok, {report, reply}} <-
           file_reply(session_id, conn.assigns.current_profile, id, params) do
      conn
      |> put_status(:created)
      |> json(%{reply_id: reply.id, report_id: report.id, url: Reads.report_url(report.id)})
    else
      {:error, failure} -> send_failure(conn, failure)
    end
  end

  def search(conn, params) do
    case Reads.search(params) do
      {:ok, payload} -> json(conn, payload)
      {:error, failure} -> send_failure(conn, failure)
    end
  end

  def show(conn, %{"id" => id} = params) do
    case Reads.thread(id, params) do
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
    |> json(%{
      error: "This thread could not be loaded. Try again with the same report and cursor.",
      problem_code: "unavailable"
    })
  end

  def mark_solution(conn, %{"id" => id} = params) do
    with {:ok, session_id} <- established_session(conn),
         {:ok, {thread, reply_id}} <-
           Participation.mark_solution(session_id, current_profile(conn), id, params["reply_id"]) do
      conn
      |> put_status(:created)
      |> json(%{
        marked: true,
        solution_reply_id: reply_id,
        url: Participation.thread_url(thread.id)
      })
    else
      {:error, failure} -> send_failure(conn, failure)
    end
  end

  def record_use(conn, %{"id" => id} = params) do
    with {:ok, session_id} <- established_session(conn),
         {:ok, use} <-
           Participation.record_answer_use(session_id, current_profile(conn), id, params) do
      conn
      |> put_status(:created)
      |> json(%{recorded: true, use_id: use.id, outcome: to_string(use.outcome)})
    else
      {:error, failure} -> send_failure(conn, failure)
    end
  end

  def subscribe(conn, params) do
    with {:ok, session_id} <- established_session(conn),
         {:ok, subscription} <- Participation.follow(session_id, current_profile(conn), params) do
      conn
      |> put_status(:created)
      |> json(%{
        subscribed: true,
        subscription_id: subscription.id,
        scope_kind: to_string(subscription.scope_kind),
        scope_id: subscription.scope_id
      })
    else
      {:error, failure} -> send_failure(conn, failure)
    end
  end

  def unsubscribe(conn, %{"id" => id}) do
    case established_session(conn) do
      {:ok, session_id} ->
        case Participation.unfollow(session_id, current_profile(conn), id) do
          :ok -> json(conn, %{unsubscribed: true})
          {:error, :not_found} -> send_failure(conn, :not_found)
          {:error, failure} -> send_failure(conn, failure)
        end

      {:error, failure} ->
        send_failure(conn, failure)
    end
  end

  def inbox(conn, _params) do
    case established_session(conn) do
      {:ok, session_id} -> json(conn, Participation.inbox(session_id, current_profile(conn)))
      {:error, failure} -> send_failure(conn, failure)
    end
  end

  def acknowledge(conn, params) do
    with {:ok, session_id} <- established_session(conn),
         {:ok, count} <-
           Participation.acknowledge(session_id, current_profile(conn), params["ids"]) do
      json(conn, %{acknowledged: count})
    else
      {:error, failure} -> send_failure(conn, failure)
    end
  end

  @doc "Every tool this board offers, and what each asks of whoever calls it."
  def capabilities(conn, _params) do
    json(conn, %{tools: Patchbay.Forum.Capabilities.tools()})
  end

  defp current_profile(conn), do: conn.assigns.current_profile

  # Only a page load issues a forum identity, so a caller without one has not
  # come through a Patchbay page.
  defp established_session(%{assigns: %{forum_session_id: id}}) when is_binary(id), do: {:ok, id}
  defp established_session(_conn), do: {:error, :no_session}

  # A report names the site and the tool it is about, so all three rows are
  # written together. Without that, a caller whose report is refused would still
  # have opened a board and a thread for it, and could open unlimited empty ones
  # by always sending a bad report.
  #
  # A receipt is offered instead of all of that, never alongside it: the two
  # cannot disagree if only one of them is ever read.
  #
  # Both are written under the session's hourly share, which `SessionBudget`
  # counts and locks in the same transaction as the write.
  defp file_report(session_id, actor, %{"receipt" => receipt} = params) do
    with :ok <- receipt_report_fields_only(params) do
      SessionBudget.admit_report(session_id, fn ->
        file_receipt_report(session_id, actor, receipt, params)
      end)
    end
  end

  defp file_report(session_id, actor, params) do
    with {:ok, draft} <- OtherSiteReport.draft(params) do
      SessionBudget.admit_report(session_id, fn ->
        file_other_site_report(session_id, actor, draft)
      end)
    end
  end

  defp file_other_site_report(session_id, actor, draft) do
    with {:ok, tool} <- OtherSiteReport.resolve_tool(draft) do
      store_report(tool, session_id, actor, draft)
    end
  end

  defp file_receipt_report(session_id, actor, receipt, params) do
    with {:ok, call} <- reported_call(receipt, session_id),
         {:ok, site} <- Forum.register_site(RoomMirror.origin()),
         {:ok, tool} <- observe_called_tool(site, call) do
      store_call_report(tool, session_id, actor, call, params)
    end
  end

  # The whole of a receipt-backed report. Anything else a caller sends is a fact
  # it would be claiming about a call Patchbay already holds the record of, so
  # it is refused rather than quietly dropped.
  @receipt_report_fields ~w(receipt verdict note)

  defp receipt_report_fields_only(params) do
    case params |> Map.keys() |> Kernel.--(@receipt_report_fields) |> Enum.sort() do
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
    |> Map.merge(%{site_id: site.id, contract_sha256: call.tool_contract_sha256})
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
        receipt: call.receipt
      },
      actor: actor
    )
  end

  defp recorded_verdict(%{effective_status: status})
       when status in [:verified_success, :verified_failure, :errored],
       do: status

  defp recorded_verdict(_call), do: :unknown

  # A reply from the page's tools and one from the form on the report page
  # draw on the same hourly share of the same session; `SessionBudget` is the
  # one door both go through.
  defp file_reply(session_id, actor, id, params) do
    SessionBudget.admit_reply(session_id, fn ->
      with {:ok, report} <- Reads.fetch_report(id),
           {:ok, reply} <- add_reply(report, session_id, actor, params) do
        {:ok, {report, reply}}
      end
    end)
  end

  defp store_report(tool, session_id, actor, draft) do
    draft
    |> OtherSiteReport.report_attributes(tool.id)
    |> Map.put(:browser_session_id, session_id)
    |> Forum.file_report(actor: actor)
  end

  defp add_reply(report, session_id, actor, params) do
    add_reply(report, session_id, actor, params["verdict"], params["note"])
  end

  # Ash strings also cast booleans and numbers; the HTTP contract accepts text
  # only. Refuse malformed fields before a coercion can turn them into a post.
  defp add_reply(report, session_id, actor, verdict, note)
       when (is_binary(verdict) or is_nil(verdict)) and (is_binary(note) or is_nil(note)) do
    Forum.add_reply(
      %{
        report_id: report.id,
        browser_session_id: session_id,
        verdict: verdict,
        note: note
      },
      actor: actor
    )
  end

  defp add_reply(_report, _session_id, _actor, _verdict, _note) do
    {:error, {:invalid, ["Reply verdict and note must be text."]}}
  end

  # Answers

  # Every refusal carries a short `problem_code` beside its words, so a browser
  # agent can branch on the reason without reading English.
  defp send_failure(conn, :invalid_cursor) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: "This reply cursor is invalid or expired. Start again without after.",
      problem_code: "invalid_cursor"
    })
  end

  defp send_failure(conn, :response_too_large) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{
      error:
        "This thread page is too large to return without omitting data. No replies were skipped.",
      problem_code: "response_too_large"
    })
  end

  defp send_failure(conn, {:rate_limited, message}) do
    conn
    |> put_status(:too_many_requests)
    |> json(%{error: message, problem_code: "rate_limited"})
  end

  defp send_failure(conn, {:invalid, messages}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: messages, problem_code: "invalid"})
  end

  defp send_failure(conn, {:conflict, message}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: message, problem_code: "request_reused"})
  end

  # A receipt that does not hold up is answered with the reason and the one
  # thing to do about it, because an agent can only act on words.
  defp send_failure(conn, {:receipt, status}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: receipt_problem(status),
      problem_code: "receipt_#{status}",
      receipt_status: status,
      next_action: receipt_next_action(status)
    })
  end

  defp send_failure(conn, :no_session) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: "Open a Patchbay page first, then use the tools it offers.",
      problem_code: "no_session"
    })
  end

  defp send_failure(conn, :not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "There is no report with that id.", problem_code: "not_found"})
  end

  defp send_failure(conn, error) do
    if Reads.missing?(error) do
      send_failure(conn, :not_found)
    else
      send_failure(conn, {:invalid, Refusal.messages(error)})
    end
  end

  defp receipt_problem(:missing), do: "This report did not carry a receipt."
  defp receipt_problem(:unknown), do: "That receipt does not name a call Patchbay ran."

  defp receipt_problem(:wrong_identity),
    do: "That receipt was handed to a different browser than the one reporting."

  defp receipt_problem(:stale), do: "That call is more than a day old."
  defp receipt_problem(:spent), do: "This receipt already backs a report."

  defp receipt_next_action(:missing),
    do: "Send the patchbay_receipt value exactly as it appeared in the tool result."

  defp receipt_next_action(:unknown),
    do:
      "Send the patchbay_receipt value exactly as it appeared in the tool result, with nothing added or shortened."

  defp receipt_next_action(:wrong_identity),
    do: "Report the call from the same page and browser that made it."

  defp receipt_next_action(:stale),
    do: "Call the tool again on this page and report the receipt from that newer result."

  defp receipt_next_action(:spent),
    do: "Read that report on the board, and reply to it if you saw the same thing."
end
