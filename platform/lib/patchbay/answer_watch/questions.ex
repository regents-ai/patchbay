defmodule Patchbay.AnswerWatch.Questions do
  @moduledoc """
  The questions the weekly answer check asks, each with who asks it
  (`persona`), how far along they are (`stage`) and what it is about
  (`topic`). A question's words are its identity: rewording one starts a new
  question, and the weeks already recorded keep the old words.

  The list follows the AI search plan's seed questions. A question about
  "[site]" in the plan is asked here about one real site.
  """

  @personas [:agent_builders, :site_teams, :wallet_teams, :agents, :security, :marketers]
  @stages [:stuck, :looking, :comparing, :choosing]
  @topics [:agent_help, :webmcp, :wallets, :incidents, :offers, :patchbay]

  @type t :: %{question: String.t(), persona: atom(), stage: atom(), topic: atom()}

  @questions [
    # People running Claude Code, Codex, Hermes and other agents.
    {:agent_builders, :stuck, :agent_help, "Claude Code can't sign in to a website, what now?"},
    {:agent_builders, :stuck, :agent_help,
     "My AI agent keeps failing on a website form. How do I fix it?"},
    {:agent_builders, :stuck, :agent_help,
     "Codex browser tool times out on a checkout page. What can I do?"},
    {:agent_builders, :stuck, :webmcp, "Hermes agent can't use a website's tools. Why?"},
    {:agent_builders, :looking, :agent_help, "Where can AI agents report broken website tools?"},
    {:agent_builders, :looking, :agent_help, "Is there a Stack Overflow for AI agents?"},
    {:agent_builders, :looking, :agent_help, "How do AI agents share fixes with each other?"},
    {:agent_builders, :looking, :agent_help,
     "How do I give my coding agent a skill for asking for help?"},
    {:agent_builders, :looking, :wallets, "Can Claude Code use a crypto wallet?"},
    {:agent_builders, :looking, :wallets,
     "How do I let my coding agent pay for an API with x402?"},
    {:agent_builders, :comparing, :agent_help,
     "What is the best coding agent for using websites in 2026?"},
    {:agent_builders, :comparing, :agent_help,
     "Claude Code vs Codex for browser tasks: which is better?"},
    {:agent_builders, :comparing, :webmcp, "Which AI agents support WebMCP?"},
    {:agent_builders, :choosing, :patchbay, "How do I install the Patchbay skill?"},
    {:agent_builders, :choosing, :patchbay, "What are the regents patchbay commands?"},
    {:agent_builders, :choosing, :patchbay, "Is there a Patchbay MCP server?"},
    # Teams making their website usable by agents.
    {:site_teams, :stuck, :agent_help, "AI agents can't use my web app. What should I change?"},
    {:site_teams, :stuck, :webmcp, "How do I check if my website is agent-ready?"},
    {:site_teams, :stuck, :webmcp, "My WebMCP tool is not working. How do I debug it?"},
    {:site_teams, :stuck, :agent_help, "Why do AI agents fail on my checkout?"},
    {:site_teams, :looking, :webmcp, "What is WebMCP?"},
    {:site_teams, :looking, :webmcp, "How do I add WebMCP tools to my site?"},
    {:site_teams, :looking, :webmcp, "WebMCP vs an MCP server: what is the difference?"},
    {:site_teams, :looking, :webmcp, "llms.txt vs WebMCP: which does my site need?"},
    {:site_teams, :looking, :webmcp, "How do AI agents find a website's tools?"},
    {:site_teams, :comparing, :webmcp, "Which websites support WebMCP?"},
    {:site_teams, :comparing, :webmcp, "What are examples of WebMCP tools on real sites?"},
    {:site_teams, :comparing, :agent_help, "Which ecommerce sites are agent-ready?"},
    {:site_teams, :choosing, :webmcp, "How do I test my WebMCP tools with real agents?"},
    {:site_teams, :choosing, :agent_help, "How can I see which AI agents fail on my site?"},
    {:site_teams, :choosing, :agent_help,
     "Where can I find agent tool error reports for my site?"},
    {:site_teams, :choosing, :webmcp, "How do I set up the WebMCP Chrome origin trial?"},
    # Wallet and payments teams: the Wallet Bench's readers.
    {:wallet_teams, :stuck, :wallets, "Can AI agents use a crypto wallet?"},
    {:wallet_teams, :stuck, :wallets, "How do I give an AI agent a crypto wallet safely?"},
    {:wallet_teams, :stuck, :wallets, "My AI agent's wallet setup keeps failing. Why?"},
    {:wallet_teams, :stuck, :wallets, "Is it safe to let an AI agent hold a private key?"},
    {:wallet_teams, :looking, :wallets,
     "Is there a benchmark of AI agents using crypto wallets?"},
    {:wallet_teams, :looking, :wallets, "Which wallet works with x402 payments for AI agents?"},
    {:wallet_teams, :looking, :wallets, "Where do AI agents store wallet keys?"},
    {:wallet_teams, :looking, :wallets, "Can Codex CLI create a crypto wallet?"},
    {:wallet_teams, :comparing, :wallets,
     "What is the best crypto wallet for AI agents in 2026?"},
    {:wallet_teams, :comparing, :wallets,
     "Privy vs Coinbase CDP for AI agents: which is better?"},
    {:wallet_teams, :comparing, :wallets, "Turnkey vs Privy for agent wallets: which is better?"},
    {:wallet_teams, :comparing, :wallets, "Which crypto wallets work with Claude Code?"},
    {:wallet_teams, :comparing, :wallets, "Can Claude Code use a Bankr wallet?"},
    {:wallet_teams, :comparing, :wallets, "Does the MoonPay CLI work with AI coding agents?"},
    {:wallet_teams, :comparing, :wallets, "Does the Zerion CLI work with AI coding agents?"},
    {:wallet_teams, :choosing, :wallets, "How do I get my wallet tested with AI coding agents?"},
    {:wallet_teams, :choosing, :wallets, "Where can I get an agent wallet compatibility report?"},
    # Agents searching in the middle of a task.
    {:agents, :stuck, :agent_help, "ramp clear_table_filters tool fails. How do I fix it?"},
    {:agents, :stuck, :agent_help, "A Shopify agent tool returns an error. What should I do?"},
    {:agents, :looking, :agent_help, "Are there known fixes for Ramp's agent tools?"},
    {:agents, :looking, :agent_help, "Has anyone else hit this website tool error?"},
    # Security and operations during a live incident.
    {:security, :stuck, :incidents, "CVE-2026-109618 in PHP: what should I do now?"},
    {:security, :stuck, :incidents, "eMudhra certificate keys recoverable: am I affected?"},
    {:security, :stuck, :incidents, "TiDB Cloud incident: what should I check?"},
    # Developer-tool marketers: the Offers buyers.
    {:marketers, :looking, :offers, "How do I advertise to AI agents?"},
    {:marketers, :looking, :offers, "How do I reach AI coding agents with my developer tool?"},
    {:marketers, :looking, :offers, "How does advertising to AI agents work?"},
    {:marketers, :looking, :offers, "Where do AI coding agents look for developer tools?"}
  ]

  for {persona, stage, topic, _question} <- @questions do
    unless persona in @personas and stage in @stages and topic in @topics do
      raise "unknown persona, stage or topic: #{inspect({persona, stage, topic})}"
    end
  end

  # The words are the identity, so no two questions may share them.
  @questions
  |> Enum.frequencies_by(&elem(&1, 3))
  |> Enum.each(fn {question, count} ->
    if count > 1, do: raise("question listed twice: #{question}")
  end)

  @doc "Every tracked question."
  @spec all() :: [t()]
  def all do
    for {persona, stage, topic, question} <- @questions,
        do: %{question: question, persona: persona, stage: stage, topic: topic}
  end

  @doc "The tracked question with these exact words, if it is still tracked."
  @spec find(String.t()) :: t() | nil
  def find(question), do: Enum.find(all(), &(&1.question == question))

  @doc "Who asks: the personas a question can belong to."
  @spec personas() :: [atom()]
  def personas, do: @personas

  @doc "How far along the asker is."
  @spec stages() :: [atom()]
  def stages, do: @stages

  @doc "What a question is about."
  @spec topics() :: [atom()]
  def topics, do: @topics
end
