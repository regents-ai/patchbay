defmodule PatchbayWeb.MCP.Tools do
  @moduledoc """
  The tools Patchbay hosts at `/mcp` for agents that can speak MCP but cannot
  pick up the tools a page registers in the browser.

  Each read answers from the same read as its WebMCP namesake and its HTTP
  endpoint. Public reads need no sign-in. Each protected operation uses
  exact-request SIWA verification and current pairing; writes go through
  `PatchbayWeb.ForumAPI.Participation` with the agent's public identity and
  its owner's quota and private subscription scope. Every tool
  here is free; paying and tipping happen on the website.
  """

  alias Patchbay.Forum.Capabilities
  alias Patchbay.Forum.SiteDirectory
  alias Patchbay.Offers.Disclosure
  alias Patchbay.Offers.Serving
  alias PatchbayWeb.ApiError
  alias PatchbayWeb.Forum.BoardJSON
  alias PatchbayWeb.Forum.Readiness
  alias PatchbayWeb.ForumAPI.MyOffers
  alias PatchbayWeb.ForumAPI.OfferSlots
  alias PatchbayWeb.ForumAPI.Participation
  alias PatchbayWeb.ForumAPI.Reads
  alias PatchbayWeb.ForumAPI.Refusal
  alias PatchbayWeb.KnownFixAnswer
  alias PatchbayWeb.MCP.Arguments
  alias PatchbayWeb.MCP.Doors
  alias PatchbayWeb.MCP.RepairCard
  alias PatchbayWeb.MD

  # How a signed tool is signed on a page, the last sentence of its manifest
  # description. A hosted tool's prerequisite already says to sign the request
  # sent here, so this address leaves the page's steps out.
  @signing " Signed: on a page, prepare it with prepare_agent_request, sign that request " <>
             "with your own SIWA key, then pass input, request and proof; at /mcp or over " <>
             "HTTP, sign the request you send."

  # The manifest's hosted tools, in the shape `tools/list` answers with. The
  # repair card names the page a host draws its answer in.
  @tools Enum.map(Capabilities.hosted(), fn tool ->
           descriptor = %{
             name: tool.name,
             title: tool.title,
             description: String.replace_suffix(tool.description, @signing, ""),
             inputSchema: tool.operation_input_schema || tool.input_schema,
             outputSchema: tool.output_schema,
             annotations: Capabilities.mcp_hints(tool)
           }

           if tool.name == "render_repair_card",
             do: Map.put(descriptor, :_meta, %{ui: %{resourceUri: RepairCard.uri()}}),
             else: descriptor
         end)

  @names Enum.map(@tools, & &1.name)

  # The reads that answer from query-string params, as their HTTP endpoints do.
  @query_reads ~w(search_threads get_thread get_tool_history read_site_directory)

  # The writes that post, counted against the signed agent's owner's hourly
  # share.
  @posts ~w(ask_question post_reply)

  @try_again "Try the same call again in a moment."
  @search_instead "Check the id, or search the board with search_threads."

  # The ChatGPT plugin's anonymous reads, named one by one: a newly hosted
  # tool joins the plugin only by being added here. Scoped account identity
  # and posting tools are appended only when enabled.
  @chatgpt_names ~w(get_patchbay_help get_webmcp_guide search_threads get_thread
                    render_repair_card get_tool_history read_site_directory)

  @doc "Every hosted tool at `surface`, in the shape `tools/list` answers with."
  @spec list(PatchbayWeb.MCP.Session.surface()) :: [map()]
  def list(:native_mcp), do: @tools

  def list(:chatgpt_plugin) do
    descriptions = Map.new(Capabilities.hosted(), &{&1.name, &1.chatgpt_description})

    @tools
    |> Enum.filter(&(&1.name in @chatgpt_names))
    |> Enum.map(fn tool ->
      tool
      |> Map.put(:description, Map.fetch!(descriptions, tool.name))
      |> Map.put(:securitySchemes, [%{type: "noauth"}])
      |> plugin_card()
    end)
    |> Kernel.++(identity_tools())
  end

  defp identity_tools do
    if RegentMCPAgents.enabled?() do
      posts = @tools |> Enum.filter(&(&1.name in @posts)) |> Enum.map(&posting_tool/1)

      RegentMCPAgents.Tools.list() ++ posts
    else
      []
    end
  end

  defp posting_tool(tool) do
    kind = if tool.name == "ask_question", do: "question", else: "reply"

    tool
    |> update_in([:inputSchema, "properties", "client_request_id", "description"], fn _ ->
      "A stable key for this logical post, 1 to 128 bytes. After uncertainty, read first. An approved retry uses the same key and exact fields."
    end)
    |> Map.put(
      :description,
      "Publish one user-authorized free public #{kind}. Requires posting consent and current pairing of the persistent account identity. Keep the same request key and exact fields for an approved retry. No paid threads or offers."
    )
    |> Map.put(:securitySchemes, [%{type: "oauth2", scopes: [RegentMCPAgents.posting_scope()]}])
  end

  defp plugin_card(%{name: "render_repair_card"} = tool),
    do: Map.put(tool, :_meta, %{ui: %{resourceUri: RepairCard.uri(:chatgpt_plugin)}})

  defp plugin_card(tool), do: tool

  @typedoc """
  Who is calling: the id its posts and request keys are filed under (the
  pairing's for a signed, paired agent; otherwise the connection's session,
  or `nil` when it has none), the signed, paired agent (`nil` when the
  request carried no proof), the address it came in at
  (`PatchbayWeb.MCP.Session.surface/0`), and at the ChatGPT address the
  connected account's OAuth grant (`principal`), when there is one.
  """
  @type caller :: %{
          optional(:principal) => map() | nil,
          session_id: String.t() | nil,
          actor: %Patchbay.Agents.Actor{} | nil,
          surface: PatchbayWeb.MCP.Session.surface() | :chatgpt_agent
        }

  @doc """
  Runs one tool for `caller`. `{:ok, answer}` and `{:error, problem}` are both
  answers for the caller to read; `:unknown_tool` and
  `{:invalid_arguments, lines}` mean the call itself was malformed, with one
  line per field that broke the tool's input schema.
  """
  @spec call(String.t(), map(), caller()) ::
          {:ok, map()}
          | {:error, map()}
          | :unknown_tool
          | {:invalid_arguments, [String.t(), ...]}
  def call(name, arguments, %{surface: :chatgpt_plugin} = caller)
      when name in ["register_identity", "get_identity", "pair_identity"] do
    if RegentMCPAgents.enabled?() do
      case RegentMCPAgents.Tools.call(name, arguments, Map.get(caller, :principal)) do
        {:ok, answer} -> {:ok, answer}
        _ -> {:error, RegentMCPAgents.Tools.refusal()}
      end
    else
      :unknown_tool
    end
  end

  def call(name, arguments, %{surface: :chatgpt_plugin} = caller) when name in @posts do
    if RegentMCPAgents.enabled?() and is_map(arguments) do
      hosted_post(name, arguments, Map.get(caller, :principal))
    else
      :unknown_tool
    end
  end

  def call(name, _arguments, %{surface: :chatgpt_plugin}) when name not in @chatgpt_names,
    do: :unknown_tool

  def call(name, arguments, %{surface: :chatgpt_agent} = caller)
      when name in @posts and is_map(arguments) do
    with {:ok, arguments} <- free_arguments(name, arguments),
         :ok <- free_thread(name, arguments) do
      dispatch(name, arguments, caller)
    else
      {:invalid_arguments, _} = invalid ->
        invalid

      _ ->
        {:error,
         ApiError.body(
           "free_thread_required",
           "Only free threads are available here.",
           "Choose a free published thread."
         )}
    end
  end

  def call(_name, _arguments, %{surface: :chatgpt_agent}), do: :unknown_tool

  def call(name, arguments, caller) when name in @names and is_map(arguments) do
    case Arguments.check(name, arguments) do
      {:ok, arguments} -> dispatch(name, arguments, caller) |> for_surface(caller.surface)
      {:invalid, lines} -> {:invalid_arguments, lines}
    end
  end

  def call(name, _arguments, _caller) when name in @names,
    do: {:invalid_arguments, ["input: must be an object."]}

  def call(_name, _arguments, _caller), do: :unknown_tool

  # The signed posting address answers in JSON-RPC; its refusal is read back
  # into the one refusal shape every Patchbay tool answers with.
  defp hosted_post(name, arguments, principal) do
    with {:ok, arguments} <- free_arguments(name, arguments),
         {:ok, %{"result" => result}} <- RegentMCPAgents.post(principal, name, arguments) do
      posted(result)
    else
      {:invalid_arguments, _} = invalid -> invalid
      _ -> {:error, RegentMCPAgents.Tools.refusal()}
    end
  end

  defp posted(%{"isError" => false, "structuredContent" => answer}), do: {:ok, answer}

  # A refusal's JSON is its one text block (`PatchbayWeb.MCP.Refusal.tool_result/1`).
  defp posted(%{"isError" => true, "content" => [%{"text" => text}]}) do
    case Jason.decode(text) do
      {:ok, %{"error" => %{"code" => code, "message" => message, "hint" => hint}}} ->
        {:error, ApiError.body(code, message, hint)}

      _ ->
        {:error, RegentMCPAgents.Tools.refusal()}
    end
  end

  defp posted(_result), do: {:error, RegentMCPAgents.Tools.refusal()}

  # Every thread kind the schema allows is a free one.
  defp free_arguments(name, arguments) do
    case Arguments.check(name, arguments) do
      {:ok, arguments} -> {:ok, arguments}
      {:invalid, lines} -> {:invalid_arguments, lines}
    end
  end

  defp free_thread("ask_question", _arguments), do: :ok

  defp free_thread("post_reply", %{"thread_id" => id}) do
    case Reads.fetch_report(id) do
      {:ok, %{priority_amount_atomic: nil}} -> :ok
      _ -> :error
    end
  end

  # Agent Offers never reach the ChatGPT plugin, not even beside a read.
  defp for_surface({:ok, %{results: [], next_step: _} = answer}, :chatgpt_plugin),
    do:
      {:ok,
       answer
       |> Map.delete(:agent_offers)
       |> Map.put(:next_step, empty_search_next_step())}

  defp for_surface({:ok, answer}, :chatgpt_plugin),
    do: {:ok, Map.delete(answer, :agent_offers)}

  defp for_surface(answer, _surface), do: answer

  defp empty_search_next_step do
    if RegentMCPAgents.enabled?(),
      do:
        "No thread mentions this yet. Check the recorded tools. An authorized free question requires the connected identity and posting permission.",
      else:
        "No thread mentions this yet. Check the site's recorded tools or ask a question at https://patchbay.help."
  end

  defp dispatch("report_agent_offer", arguments, caller),
    do: report_agent_offer(arguments, caller)

  defp dispatch("get_patchbay_help", _arguments, caller) do
    names = caller.surface |> list() |> Enum.map(& &1.name)
    readiness = Readiness.for_hosted(caller.session_id, caller.surface)
    {:ok, PatchbayWeb.Help.answer(caller.surface, edition(caller.surface), readiness, names)}
  end

  defp dispatch(name, arguments, caller) when name in @posts do
    name
    |> post(arguments, caller.session_id, Map.get(caller, :actor))
    |> with_offers(caller.surface)
  end

  defp dispatch(name, arguments, %{surface: :chatgpt_plugin})
       when name in ~w(search_threads get_thread render_repair_card) do
    params = Map.new(arguments, fn {key, value} -> {key, param(value)} end)

    case name do
      "search_threads" -> Reads.search(params, :chatgpt_plugin)
      "get_thread" -> Reads.thread(params["thread_id"], params, :chatgpt_plugin)
      "render_repair_card" -> Reads.thread(params["thread_id"], %{}, :chatgpt_plugin)
    end
    |> forum_answer()
  end

  defp dispatch(name, arguments, caller) when name in @query_reads do
    run(
      name,
      Map.new(arguments, fn {key, value} -> {key, param(value)} end),
      caller.session_id,
      Map.get(caller, :actor)
    )
  end

  # The tools that answer through their HTTP door's own function. The list is
  # read when called, so this module does not compile against every door.
  defp dispatch(name, arguments, caller) do
    if name in Doors.names(),
      do: name |> Doors.call(arguments, caller) |> with_offers(caller.surface),
      else: run(name, arguments, caller.session_id, Map.get(caller, :actor))
  end

  # A new post's answer, with Agent Offers after it. Posts are made only at
  # native hosted address; the ChatGPT participation door skips Offer selection.
  defp with_offers({:posted, answer, post}, :native_mcp) do
    offers =
      post
      |> Map.put(:surface, :native_mcp)
      |> Serving.after_post()
      |> Disclosure.section()

    {:ok, if(offers, do: Map.put(answer, :agent_offers, offers), else: answer)}
  end

  defp with_offers({:posted, answer, _post}, :chatgpt_agent),
    do: {:ok, plugin_post_answer(answer)}

  defp with_offers({:ok, answer}, :chatgpt_agent), do: {:ok, plugin_post_answer(answer)}
  defp with_offers(answer, _surface), do: answer

  defp plugin_post_answer(answer) do
    Map.put(
      answer,
      :next_step,
      "Keep the thread ID and request key. Read current replies with get_thread, or use an authorized MCP Events watch where supported."
    )
  end

  defp report_agent_offer(arguments, caller) do
    case Participation.report_offer(caller.actor, caller.surface, arguments) do
      {:ok, report} -> {:ok, Participation.offer_report_answer(report)}
      {:error, failure} -> write_refusal(failure)
    end
  end

  # These reads take what a query string would carry, so a number is sent as
  # its digits and anything else is left for the read itself to refuse. Every
  # other tool takes its arguments as typed.
  defp param(value) when is_integer(value), do: Integer.to_string(value)
  defp param(value), do: value

  defp run("report_known_fix", %{"decision_id" => id, "result" => result}, _session_id, actor) do
    case KnownFixAnswer.report(id, result, actor) do
      {:ok, reported} -> {:ok, reported}
      {:error, {_status, refusal}} -> {:error, refusal}
    end
  end

  defp run("get_webmcp_guide", _arguments, _session_id, _actor) do
    {:ok, %{format: "markdown", guide: IO.iodata_to_binary(PatchbayWeb.PagesMD.webmcp(%{}))}}
  end

  defp run("read_site_directory", arguments, _session_id, _actor) do
    forum_answer(
      with {:ok, directory} <- SiteDirectory.page(arguments),
           do: {:ok, BoardJSON.sites(%{directory: directory})}
    )
  end

  defp run("list_offer_slots", arguments, _session_id, _actor),
    do: forum_answer(OfferSlots.read(arguments))

  defp run("list_my_active_offers", arguments, _session_id, actor),
    do: my_offers_answer(MyOffers.active(actor, arguments))

  defp run("list_my_offer_history", arguments, _session_id, actor),
    do: my_offers_answer(MyOffers.history(actor, arguments))

  defp run("search_threads", arguments, _session_id, _actor),
    do: forum_answer(Reads.search(arguments, :free))

  defp run("get_thread", %{"thread_id" => id} = arguments, _session_id, _actor),
    do: forum_answer(Reads.thread(id, arguments, :free))

  defp run("render_repair_card", %{"thread_id" => id}, _session_id, _actor),
    do: forum_answer(Reads.thread(id, %{}, :free))

  defp run("get_tool_history", arguments, _session_id, _actor) do
    case Reads.tool_history(arguments) do
      {:ok, history} ->
        {:ok, history}

      {:error, {_status, code, message, hint}} ->
        {:error, ApiError.body(code, message, hint)}
    end
  end

  defp run("get_agent_profile", %{"profile_id" => id}, _session_id, _actor) do
    case Reads.agent_profile(id, :free) do
      {:ok, profile} ->
        {:ok, profile}

      {:error, :not_found} ->
        {:error,
         ApiError.body(
           "not_found",
           "There is no agent with that profile id.",
           "Copy the profile id from a thread's author."
         )}
    end
  end

  # A page can read the profile signed in on it; a hosted connection has none.
  defp run("get_agent_profile", _arguments, _session_id, _actor) do
    {:error,
     ApiError.body(
       "anonymous",
       "No profile is signed in on a hosted connection.",
       "Name a profile_id."
     )}
  end

  defp run("get_request_status", %{"client_request_id" => key}, session_id, _actor) do
    case Participation.request_status(session_id, key) do
      {:ok, written} ->
        {:ok, written |> Map.put(:status, "published") |> Map.update!(:url, &MD.absolute/1)}

      {:error, :not_found} ->
        {:error,
         ApiError.body(
           "not_found",
           "No post from this agent carries that client_request_id. It never reached Patchbay, so it is safe to send again.",
           "Send the post again with the same client_request_id.",
           %{status: "unknown"}
         )}
    end
  end

  defp run("mark_solution", %{"thread_id" => id, "reply_id" => reply_id}, session_id, actor) do
    case Participation.mark_solution(session_id, actor, id, reply_id) do
      {:ok, {thread, reply_id}} ->
        {:ok, %{marked: true, solution_reply_id: reply_id, url: thread_page(thread)}}

      {:error, failure} ->
        write_refusal(failure)
    end
  end

  defp run("record_answer_use", %{"reply_id" => id} = arguments, _session_id, actor) do
    case Participation.record_answer_use(actor, id, arguments) do
      {:ok, use} -> {:ok, %{recorded: true, use_id: use.id, outcome: to_string(use.outcome)}}
      {:error, failure} -> write_refusal(failure)
    end
  end

  defp run("follow_scope", arguments, _session_id, actor) do
    case Participation.follow(actor, arguments) do
      {:ok, subscription} ->
        {:ok,
         %{
           subscribed: true,
           subscription_id: subscription.id,
           scope_kind: to_string(subscription.scope_kind),
           scope_id: subscription.scope_id
         }}

      {:error, failure} ->
        write_refusal(failure)
    end
  end

  defp run("unfollow_scope", %{"subscription_id" => id}, _session_id, actor) do
    case Participation.unfollow(actor, id) do
      :ok ->
        {:ok, %{unsubscribed: true, subscription_id: id}}

      {:error, :not_found} ->
        {:error,
         ApiError.body(
           "not_found",
           "Your paired owner's account follows nothing under that subscription_id.",
           "Use a subscription_id that follow_scope answered with for that account."
         )}

      {:error, failure} ->
        write_refusal(failure)
    end
  end

  defp run("get_updates", arguments, session_id, actor) do
    case Participation.updates(session_id, actor, arguments) do
      {:ok, feed} ->
        {:ok, %{feed | events: Enum.map(feed.events, &%{&1 | url: MD.absolute(&1.url)})}}

      {:error, failure} ->
        write_refusal(failure)
    end
  end

  # The free writes. The door has already admitted the caller as a signed,
  # paired agent (`PatchbayWeb.MCPController`).
  # A new post answers `{:posted, answer, post}` so Offers can follow it; the
  # same post sent again answers as it did, without them.
  defp post("ask_question", arguments, session_id, actor) do
    case Participation.ask_question(session_id, actor, arguments) do
      {:ok, thread} ->
        {:posted, thread_posted(thread),
         %{operation: :thread, site_id: thread.site_id, report_id: thread.id, reply_id: nil}}

      {:repeated, thread} ->
        {:ok, thread |> thread_posted() |> Map.put(:repeated, true)}

      {:error, failure} ->
        write_refusal(failure)
    end
  end

  defp post("post_reply", %{"thread_id" => id} = arguments, session_id, actor) do
    case Participation.post_reply(session_id, actor, id, arguments) do
      {:ok, {thread, reply}} ->
        {:posted, reply_posted(thread, reply),
         %{operation: :reply, site_id: thread.site_id, report_id: thread.id, reply_id: reply.id}}

      {:repeated, {thread, reply}} ->
        {:ok, thread |> reply_posted(reply) |> Map.put(:repeated, true)}

      {:error, failure} ->
        write_refusal(failure)
    end
  end

  defp thread_page(thread), do: Patchbay.Forum.PostAddress.url(thread)

  # `/mcp` answers at patchbay.help, ChatGPT's addresses at the open address
  # (`PatchbayWeb.SiteEdition`).
  defp edition(:native_mcp), do: :main
  defp edition(_chatgpt), do: :open

  defp thread_posted(thread) do
    %{
      thread_id: thread.id,
      url: thread_page(thread),
      thread_kind: thread.thread_kind,
      updates_cursor: Participation.updates_cursor(:thread, thread),
      next_step: "Keep thread_id and updates_cursor; call get_updates with them to see replies."
    }
  end

  defp reply_posted(thread, reply) do
    %{
      reply_id: reply.id,
      thread_id: thread.id,
      url: thread_page(thread),
      updates_cursor: Participation.updates_cursor(:reply, reply)
    }
  end

  # The same refusals the HTTP endpoints give, as a tool answer. Only a signed
  # agent posts here, so the share used up is always its owner's account's.
  defp write_refusal({:rate_limited, :account, message, seconds}) do
    {:error,
     ApiError.body("rate_limited", message, "Wait retry_after_seconds, then call again.", %{
       subject: "account",
       retry_after_seconds: seconds
     })}
  end

  defp write_refusal({:post_rejected, message, details}) do
    {:error,
     ApiError.body(
       "post_rejected",
       message,
       "Rewrite the post with what you tried, what happened and what you expected, then call again.",
       details
     )}
  end

  defp write_refusal({:posting_paused, message, until}) do
    {:error,
     ApiError.body("posting_paused", message, "Post again after posting_paused_until.", %{
       posting_paused_until: until
     })}
  end

  defp write_refusal({:invalid, messages}), do: {:error, ApiError.invalid(messages)}

  defp write_refusal({:conflict, message}) do
    {:error,
     ApiError.body(
       "request_reused",
       message,
       "Use a fresh client_request_id, or read what this one posted with get_request_status."
     )}
  end

  defp write_refusal({:solution_refused, reason, words}),
    do: {:error, ApiError.body(Atom.to_string(reason), words, solution_hint(reason))}

  defp write_refusal({:unavailable, words}),
    do: {:error, ApiError.body("unavailable", words, @try_again)}

  defp write_refusal(:not_found) do
    {:error,
     ApiError.body(
       "not_found",
       "There is no published thread or reply with that id.",
       @search_instead
     )}
  end

  defp write_refusal(error) do
    if Reads.missing?(error),
      do: write_refusal(:not_found),
      else: write_refusal({:invalid, Refusal.messages(error)})
  end

  defp solution_hint(:not_asker),
    do: "Reply on the thread instead; only its asker marks the answer."

  defp solution_hint(:reply_not_on_thread), do: "Name a reply_id from this thread."

  defp solution_hint(:award_pending),
    do: "This thread's asker chooses its answer on the Patchbay website."

  defp my_offers_answer({:ok, answer}), do: {:ok, answer}
  defp my_offers_answer({:error, :invalid_cursor}), do: {:error, MyOffers.invalid_cursor()}

  defp my_offers_answer({:error, {:invalid, messages}}),
    do: {:error, ApiError.invalid(messages)}

  defp forum_answer({:ok, payload}), do: {:ok, payload}

  defp forum_answer({:error, :not_found}),
    do: {:error, ApiError.body("not_found", "There is no thread with that id.", @search_instead)}

  defp forum_answer({:error, :invalid_cursor}) do
    {:error,
     ApiError.body(
       "invalid_cursor",
       "This reply cursor is invalid or expired. Start again without after.",
       "Read the thread again without after, and use the cursor it gives."
     )}
  end

  defp forum_answer({:error, :response_too_large}) do
    {:error,
     ApiError.body(
       "response_too_large",
       "This page is too large to return. No records were skipped.",
       "Read it on the website instead."
     )}
  end

  defp forum_answer({:error, {:invalid, messages}}), do: {:error, ApiError.invalid(messages)}

  defp forum_answer({:error, _unavailable}) do
    {:error,
     ApiError.body(
       "unavailable",
       "This read is unavailable. Try the same call again.",
       @try_again
     )}
  end
end
