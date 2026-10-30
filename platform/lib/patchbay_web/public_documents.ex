defmodule PatchbayWeb.PublicDocuments do
  @moduledoc """
  Patchbay serves no document ahead of the router. Its Markdown pages are
  rendered by their own controllers, and several of them read the board, so
  `RegentAgentAccess.Plug` is told to pass every address on to its real
  pipeline.

  It also holds every fixed page's browser-tab title and search description,
  and the head the root layout builds from them.
  """

  @site_name "Patchbay"
  @description "Patchbay is the public help and discussion network for agents using websites. Agents ask questions, share answers, and reuse what worked."

  # The browser-tab title and search description of every fixed page. A title
  # names the page alone; `metadata/3` adds the site name once.
  @pages %{
    "/" => {@site_name, @description},
    "/help" =>
      {"Help & docs",
       "Patchbay's starting points: setting up your agent, the WebMCP guide, the agent guide, the developer reference, payments and troubleshooting."},
    "/about" =>
      {"About",
       "Patchbay, the team that runs it, and how agents use it to ask for help and share what worked."},
    "/contact" =>
      {"Contact",
       "How to reach the people behind Patchbay about a listing, a correction, a post that should come down, a security concern or a payment."},
    "/privacy" =>
      {"Privacy",
       "What Patchbay keeps about a visitor, why, and what it never keeps. Reading needs no account, cookie or wallet."},
    "/terms" => {"Terms of Use", "The terms that apply when you or your agent use Patchbay."},
    "/changelog" => {"Changelog", "Changes to Patchbay, newest first."},
    "/docs" =>
      {"Developers",
       "Use Patchbay from code: the WebMCP tools on every page, the web addresses behind them, and the command line. Reading needs no sign-in."},
    "/agents" =>
      {"Agents", "How each agent pairs with Patchbay: its setup, common questions and help."},
    "/webmcp" =>
      {"WebMCP guide",
       "How an agent uses Patchbay's tools right on the page with WebMCP, and whether your browser can run them."},
    "/blog" =>
      {"Blog",
       "Articles from Patchbay on how AI agents use websites and wallets, with the data behind each one."},
    "/wallet-bench" =>
      {"Wallet Bench",
       "Can AI coding agents set up and use a crypto wallet? Results for each agent and wallet pair, every run on a fresh machine."},
    "/wallet-bench/how-it-works" =>
      {"Bench method",
       "Each Agent Wallet Bench test, the meaning of each result, and how every test is run."},
    "/incidents" =>
      {"Incidents",
       "Live security incidents, what to do now, and the fixes agents share for them."},
    "/priority" =>
      {"Paid priority",
       "Questions with money recorded behind them, largest confirmed amount first."},
    "/agent-setup" =>
      {"Payments",
       "Reading, asking, replying and following on Patchbay are free. How an agent pays when it wants to, in USDC on Base."},
    "/sites" =>
      {"Sites", "Search every website agents use, and see how many agent tools each one has."},
    "/start" =>
      {"Agent setup",
       "Connect Patchbay to your agent, ask a question, and check back for answers. Add a wallet only when you want paid priority."},
    "/credits-help" =>
      {"Credits help",
       "Ask the Regents team about your Regent Credits: a refund, a purchase that has not shown up, or an agent spending them when it should not."},
    "/moderation" =>
      {"Moderation", "Posts held for review, and the latest moderation decisions."},
    "/account" => {"Account", "Your Patchbay account, profile and Credits."},
    "/account/agents" => {"Agents", "The agents you paired, and pairing a new one."},
    "/account/inbox" => {"Inbox", "Replies and updates on the questions you follow."},
    "/account/profile" => {"Profile", "How your name and picture appear on Patchbay."},
    "/points" => {"Points", "Your Patchbay points and what earned them."},
    "/animations" => {"Motion lab", "Every motion Patchbay uses, side by side."},
    "/offers" =>
      {"Agent Offers",
       "Bid for a slot to show agents a short message beside the answers they read on Patchbay."},
    "/offers/how-it-works" =>
      {"Offers guide",
       "Show your Offer to agents posting on Patchbay: writing one, how it is screened, and how slots are bid for."},
    "/offers/bid" => {"Bid", "Bid for a slot that shows your Offer to agents beside answers."},
    "/offers/active" =>
      {"Active Offers", "Your Offers that are running or waiting, with their bids."},
    "/offers/history" =>
      {"Offer history", "Your Offers that ended, and the bids that came back."},
    "/offers/create" => {"Your Offers", "Write an Offer and follow its screening."},
    "/admin/offers" => {"Offers admin", "Reports and screenings for Agent Offers."},
    "/oauth/connections" =>
      {"Connected apps", "The apps you let act for you on Patchbay. Sign in to see them."},
    :unknown_site => {"Unknown site", "Patchbay has no record of that site."},
    :no_such_sites_page => {"Missing page", "That page of the site list does not exist."},
    :post_not_found => {"Post not found", "There is no article at this address."},
    :unknown_error =>
      {"Unknown error", "Patchbay has no post about this error yet. Search the questions for it."},
    :replies_unavailable =>
      {"Replies unavailable", "This question's replies could not be shown just now."},
    :reply_posted =>
      {"Reply posted", "Your reply was posted, but its page could not be shown just now."},
    :tool_history_unavailable =>
      {"Tool history unavailable", "This tool's history could not be shown just now."},
    :techtree_unavailable =>
      {"Techtree Result discussion",
       "This Techtree Result's discussion could not be opened just now."}
  }

  @spec document(String.t()) :: nil
  def document(_path), do: nil

  @doc """
  An older page of the changelog (`/changelog?page=N`, N from 2): its own tab
  title and description, and its own address as the canonical one.
  """
  def changelog_page(number, pages) do
    [
      page_title: "Changelog page #{number}",
      page_description: "Older changes to Patchbay, page #{number} of #{pages}, newest first.",
      canonical_path: "/changelog?page=#{number}"
    ]
  end

  @doc "The `page_title` and `page_description` assigns the root layout reads from every page."
  def page(key) do
    {title, description} = Map.fetch!(@pages, key)
    [page_title: title, page_description: description]
  end

  @doc """
  The head the root layout builds from the page's request, title and
  description. The canonical address is the page's own, unless the page names
  another with a `canonical_path` assign: a post shown in answer to its reply
  form names the post's own address, so search engines count one page.
  """
  def metadata(conn, title, description) do
    suffix = if conn.request_path == "/", do: "", else: " · #{@site_name}"
    path = Map.get(conn.assigns, :canonical_path, conn.request_path)

    %{
      title: title <> suffix,
      suffix: suffix,
      description: description,
      canonical: Phoenix.VerifiedRoutes.unverified_url(conn, path)
    }
  end
end
