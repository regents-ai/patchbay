defmodule PatchbayWeb.MCP.Doors do
  @moduledoc """
  The hosted tools at `/mcp` that answer through their HTTP door's own
  function. Each tool here calls the function its controller calls, with the
  same inputs, so its answer and its refusals are that door's body; only the
  wrapping differs (`PatchbayWeb.MCPController`).

  Who acts is the caller's signed, paired agent, which `/mcp` admitted from
  the request's own SIWA proof (`PatchbayWeb.MCP.Admission`); no argument
  names it. Every tool here is free and holds nothing: no Credits, no USDC.
  """

  alias PatchbayWeb.AgentAccountController
  alias PatchbayWeb.AssistAPI.RunController
  alias PatchbayWeb.Forum.BoardController
  alias PatchbayWeb.ForumAPI.CreditsHelpController
  alias PatchbayWeb.ForumAPI.InboxController
  alias PatchbayWeb.ForumAPI.LikeController
  alias PatchbayWeb.ForumAPI.OfferBidController
  alias PatchbayWeb.ForumAPI.ReportController
  alias PatchbayWeb.ForumAPI.SiteRefreshController
  alias PatchbayWeb.IdentityAPI.NameController
  alias PatchbayWeb.KnownFixController
  alias PatchbayWeb.WalletBenchController

  @names ~w(request_free_fix get_assist find_known_fixes get_known_fix get_subscriptions
            like_post unlike_post report_tool_problem report_tool_on_another_site
            reply_to_report account_balances account_credits_history account_points
            get_offer_bid_options ask_offer_fit save_agent_offer reword_agent_offer
            read_wallet_bench read_wallet_bench_pair read_tool_catalog set_my_agent_name
            read_inbox acknowledge_inbox_item ask_credits_help list_credits_help
            get_credits_help refresh_site delete_agent_offer)

  @doc "The hosted tools answered here."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc """
  Runs `name` for `caller` (`PatchbayWeb.MCP.Tools.caller/0`): `{:ok, body}`
  or `{:error, body}`, with the body its HTTP door answers, or
  `{:posted, body, post}` for a new report or reply, which Agent Offers may
  follow.
  """
  @spec call(String.t(), map(), map()) ::
          {:ok, map()} | {:error, map()} | {:posted, map(), map()}
  def call(name, arguments, caller), do: name |> door(arguments, caller) |> answered()

  defp door("request_free_fix", %{"args" => args}, %{actor: actor}),
    do: RunController.request_free_fix(actor, args)

  defp door("get_assist", %{"run_id" => id}, %{actor: actor}),
    do: RunController.get_assist(actor, id)

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

  defp door(name, arguments, caller)
       when name in ["report_tool_problem", "report_tool_on_another_site"],
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

  defp door("account_balances", _arguments, %{actor: actor}),
    do: AgentAccountController.account_balances(actor)

  defp door("account_credits_history", arguments, %{actor: actor}),
    do: AgentAccountController.account_credits_history(actor, arguments)

  defp door("account_points", _arguments, %{actor: actor}),
    do: AgentAccountController.account_points(actor)

  defp door("get_offer_bid_options", arguments, %{actor: actor}),
    do: OfferBidController.get_offer_bid_options(actor, arguments)

  defp door("ask_offer_fit", arguments, %{actor: actor}),
    do: OfferBidController.ask_offer_fit(actor, arguments)

  defp door("save_agent_offer", arguments, %{actor: actor}),
    do: OfferBidController.save_agent_offer(actor, arguments)

  defp door("reword_agent_offer", arguments, %{actor: actor}),
    do: OfferBidController.reword_agent_offer(actor, arguments)

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

  defp door("ask_credits_help", arguments, %{actor: actor}),
    do: CreditsHelpController.ask_credits_help(actor, arguments)

  defp door("list_credits_help", arguments, %{actor: actor}),
    do: CreditsHelpController.list_credits_help(actor, arguments)

  defp door("get_credits_help", %{"post_id" => id}, %{actor: actor}),
    do: CreditsHelpController.get_credits_help(actor, id)

  defp door("refresh_site", %{"site" => site}, %{actor: actor}),
    do: SiteRefreshController.refresh_site(actor, site)

  defp door("delete_agent_offer", %{"creative_id" => id}, %{actor: actor}),
    do: OfferBidController.delete_agent_offer(actor, id)

  # A new report or reply answers `{:posted, body, post}`; the same one sent
  # again answers as it did; a refusal is worded as its HTTP door words it.
  defp answered({:posted, body, post}), do: {:posted, body, post}
  defp answered({:repeated, body}), do: {:ok, body}

  defp answered({:refused, failure}),
    do: {:error, failure |> ReportController.refusal() |> elem(1)}

  defp answered({status, body}) do
    if Plug.Conn.Status.code(status) < 300, do: {:ok, body}, else: {:error, body}
  end
end
