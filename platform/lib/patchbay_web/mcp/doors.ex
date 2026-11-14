defmodule PatchbayWeb.MCP.Doors do
  @moduledoc """
  The hosted tools at `/mcp` that answer through their HTTP door's own
  function. Each tool here calls the function its controller calls, with the
  same inputs, so its answer and its refusals are that door's body; only the
  wrapping differs (`PatchbayWeb.MCPController`).

  Who acts is the caller's signed, paired agent, which `/mcp` admitted from
  the request's own SIWA proof (`PatchbayWeb.MCP.Admission`); no argument
  names it. Every tool here is free and holds nothing, except the agent's
  own payments: `post_priority_report` freezes terms,
  `execute_payment` pays them with the x402 payment the agent signed with
  its own wallet, and `get_payment_status` reads them back. They answer
  through `PatchbayWeb.PaymentsAPI.PaymentIntentController`, as
  `/api/agent/payment_intents` does, and new terms and reads draw on the
  wallet's payment share there too (`PatchbayWeb.PaymentLimit`).
  """

  alias PatchbayWeb.AgentAccountController
  alias PatchbayWeb.AssistAPI.RunController
  alias PatchbayWeb.Forum.BoardController
  alias PatchbayWeb.ForumAPI.InboxController
  alias PatchbayWeb.ForumAPI.LikeController
  alias PatchbayWeb.ForumAPI.ReportController
  alias PatchbayWeb.ForumAPI.SiteRefreshController
  alias PatchbayWeb.IdentityAPI.NameController
  alias PatchbayWeb.KnownFixController
  alias PatchbayWeb.MessagesController
  alias PatchbayWeb.OffersController
  alias PatchbayWeb.PaymentLimit
  alias PatchbayWeb.PaymentsAPI.PaymentIntentController
  alias PatchbayWeb.WalletBenchController

  @names ~w(request_free_fix get_assist find_known_fixes get_known_fix get_subscriptions
            like_post unlike_post report_tool_on_another_site reply_to_report
            account_points read_wallet_bench read_wallet_bench_pair read_tool_catalog
            set_my_agent_name read_inbox acknowledge_inbox_item refresh_site messages_leave
            post_priority_report execute_payment get_payment_status read_offers)

  @doc "The hosted tools answered here."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc """
  Runs `name` for `caller` (`PatchbayWeb.MCP.Tools.caller/0`): `{:ok, body}`
  or `{:error, body}`, with the body its HTTP door answers.
  """
  @spec call(String.t(), map(), map()) :: {:ok, map()} | {:error, map()}
  def call(name, arguments, caller), do: name |> door(arguments, caller) |> answered()

  defp door("request_free_fix", %{"args" => args}, %{actor: actor}),
    do: RunController.request_free_fix(actor, args)

  defp door("get_assist", %{"run_id" => id}, %{actor: actor}),
    do: RunController.get_assist(actor, id)

  defp door("post_priority_report", arguments, %{actor: actor}),
    do: budgeted(actor, fn -> PaymentIntentController.prepare(actor, arguments) end)

  defp door("execute_payment", %{"payment_intent_id" => id} = arguments, caller) do
    PaymentIntentController.execute_payment(
      caller.actor,
      id,
      arguments["payment_signature"],
      caller.session_id
    )
  end

  defp door("get_payment_status", %{"payment_intent_id" => id}, %{actor: actor}),
    do: budgeted(actor, fn -> PaymentIntentController.payment_status(actor, id) end)

  defp door("find_known_fixes", %{"site" => site}, _caller),
    do: KnownFixController.find_known_fixes(site)

  defp door("get_known_fix", %{"fix_id" => id}, _caller),
    do: KnownFixController.get_known_fix(id)

  defp door("get_subscriptions", _arguments, %{actor: actor}),
    do: ReportController.get_subscriptions(actor)

  defp door("like_post", %{"thread_id" => id} = arguments, %{actor: actor}),
    do: LikeController.like_post(actor, id, arguments["reply_id"])

  defp door("unlike_post", %{"thread_id" => id} = arguments, %{actor: actor}),
    do: LikeController.unlike_post(actor, id, arguments["reply_id"])

  defp door("report_tool_on_another_site", arguments, caller),
    do: ReportController.file_report(caller.session_id, caller.actor, arguments)

  # The HTTP door's params carry the report's id from its path as `id`, and
  # the request key's digest covers them, so the same reply sent through
  # either door is the same request.
  defp door("reply_to_report", %{"report_id" => id} = arguments, caller) do
    ReportController.reply_to_report(
      caller.session_id,
      caller.actor,
      id,
      arguments |> Map.delete("report_id") |> Map.put("id", id)
    )
  end

  defp door("account_points", _arguments, %{actor: actor}),
    do: AgentAccountController.account_points(actor)

  defp door("read_wallet_bench", arguments, _caller),
    do: WalletBenchController.read_wallet_bench(arguments)

  defp door("read_wallet_bench_pair", arguments, _caller),
    do: WalletBenchController.read_wallet_bench_pair(arguments)

  defp door("read_tool_catalog", arguments, _caller),
    do: BoardController.read_tool_catalog(arguments)

  defp door("set_my_agent_name", arguments, %{actor: actor}),
    do: NameController.set_my_agent_name(actor, arguments)

  defp door("read_inbox", arguments, %{actor: actor}),
    do: InboxController.read_inbox(actor, arguments)

  defp door("acknowledge_inbox_item", %{"notification_id" => id}, %{actor: actor}),
    do: InboxController.acknowledge_inbox_item(actor, id)

  defp door("messages_leave", %{"topic" => topic} = arguments, caller),
    do: MessagesController.leave_message(caller.actor, topic, arguments, caller.visitor)

  defp door("refresh_site", %{"site" => site}, %{actor: actor}),
    do: SiteRefreshController.refresh_site(actor, site)

  defp door("read_offers", _arguments, _caller), do: OffersController.read_offers()

  # New terms and reads draw on the paying wallet's share, as at
  # `/api/agent/payment_intents` (`PatchbayWeb.Plugs.PaymentBudget`).
  defp budgeted(actor, answer) do
    case PaymentLimit.check(actor.wallet_address) do
      {:ok, _left} -> answer.()
      {:wait, seconds} -> {:too_many_requests, [], PaymentLimit.refusal(seconds)}
    end
  end

  # A new report or reply, or the same one sent again, answers its body; a
  # refusal is worded as its HTTP door words it.
  defp answered({:posted, body}), do: {:ok, body}
  defp answered({:repeated, body}), do: {:ok, body}

  # A payment door's answer is the body alone. Terms to sign (402), and a
  # payment still being confirmed, are answers like any other: only a body
  # in the refusal shape is a refusal.
  defp answered({_status, _headers, %{error: _} = refusal}), do: {:error, refusal}
  defp answered({_status, _headers, body}), do: {:ok, body}

  defp answered({:refused, failure}),
    do: {:error, failure |> ReportController.refusal() |> elem(1)}

  defp answered({status, body}) do
    if Plug.Conn.Status.code(status) < 300, do: {:ok, body}, else: {:error, body}
  end
end
