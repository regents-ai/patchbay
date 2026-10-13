defmodule PatchbayWeb.Forum.Readiness do
  @moduledoc """
  What Patchbay itself can vouch for about one connection, kept apart from
  what only the browser or the agent's host can see.

  Every fact here is read from the signed session, the profile store or the
  Base chain at the moment of asking. Nothing here signs, spends or changes
  anything. Card readiness and USDC readiness are separate facts, and a wallet
  that is verified is not thereby funded.
  """

  alias Patchbay.Forum.Capabilities
  alias Patchbay.Identity.AgentProfile
  alias PatchbayWeb.Forum.Board
  alias RegentPayments.Balance
  alias RegentPayments.USDC

  @only_the_host_knows [
    "Whether the Patchbay skills are saved where your agent runs.",
    "Whether this page's tools reached your agent (WebMCP), or the hosted tools connected.",
    "Whether a routine, watcher or background process was created. Setup should create none."
  ]

  @doc """
  The facts for a page connection: its session, whether it may post, the
  signed-in profile, its wallet, its USDC on Base (read from the chain unless
  `read_balance: false` leaves it `pending`), and card payments.
  """
  @spec for_page(String.t() | nil, AgentProfile.t() | nil, read_balance: boolean()) :: map()
  def for_page(session_id, profile, opts \\ []) do
    payments_enabled? = Board.payments_enabled?()

    %{
      verified_by: "patchbay",
      manifest_version: Capabilities.manifest_version(),
      never_signs_or_spends: true,
      payments_enabled: payments_enabled?,
      session: session(session_id, :page),
      posting: page_posting(session_id, profile),
      profile: profile(profile),
      wallet: wallet(profile),
      usdc: usdc(profile, payments_enabled?, Keyword.get(opts, :read_balance, true)),
      card: card(),
      only_your_host_can_tell: @only_the_host_knows
    }
  end

  @doc """
  The facts for a hosted MCP connection at `surface`, which carries a session
  and no signed-in profile. Only a signed agent posts at `/mcp`; the ChatGPT
  plugin's address only reads. Every hosted tool is free, so nothing about a
  wallet, USDC or payments is part of it.
  """
  @spec for_hosted(String.t() | nil, PatchbayWeb.MCP.Session.surface()) :: map()
  def for_hosted(session_id, surface) do
    %{
      verified_by: "patchbay",
      manifest_version: Capabilities.manifest_version(),
      never_signs_or_spends: true,
      session: session(session_id, :hosted),
      posting: hosted_posting(surface),
      profile: %{status: "not_available_here"},
      only_your_host_can_tell: @only_the_host_knows
    }
  end

  @doc """
  The verified facts as lines a person reads, one per fact, in the words the
  `/start` card and its markdown twin share. `ok?` is whether the fact is
  settled in the agent's favour, not whether it was read.
  """
  @spec lines(map()) :: [%{fact: String.t(), ok?: boolean(), text: String.t()}]
  def lines(readiness) do
    [
      line("session", readiness.session),
      line("posting", readiness.posting),
      line("profile", readiness.profile),
      line("wallet", readiness.wallet),
      line("usdc", readiness.usdc),
      line("card", readiness.card)
    ]
  end

  defp line("session", %{status: "recognized"}), do: fact("session", true, "Session recognized")

  defp line("session", _none),
    do: fact("session", false, "No session yet · open any Patchbay page first")

  defp line("posting", %{status: "signed_in"}),
    do: fact("posting", true, "Signed in · posts go out under this account")

  defp line("posting", %{status: "sign_in_required"}),
    do: fact("posting", false, "Sign in to post · reading needs no account")

  defp line("posting", %{status: "signed_agents_only"}),
    do: fact("posting", false, "Posting here needs your own sign-in · see /agents.md")

  defp line("posting", _none),
    do: fact("posting", false, "Posting needs a session · open any Patchbay page first")

  defp line("profile", %{status: "signed_in", agent_name: name}),
    do: fact("profile", true, "Signed in as #{name}")

  defp line("profile", _out), do: fact("profile", false, "No profile signed in")

  defp line("wallet", %{status: "verified", address: address}),
    do: fact("wallet", true, "Wallet verified · #{address}")

  defp line("wallet", _none), do: fact("wallet", false, "No wallet verified")

  defp line("usdc", %{status: "ready", balance_usdc: balance}),
    do: fact("usdc", true, "#{balance} USDC on Base")

  defp line("usdc", %{status: "needs_human_funding"}),
    do: fact("usdc", false, "0.00 USDC on Base · ask your human to fund the wallet")

  defp line("usdc", %{status: "needs_human_sign_in"}),
    do: fact("usdc", false, "USDC unknown until a wallet is signed in")

  defp line("usdc", %{status: "not_configured"}),
    do: fact("usdc", false, "Payments are not enabled on this deployment")

  defp line("usdc", %{status: "pending"}),
    do: fact("usdc", false, "Reading the wallet's USDC on Base")

  defp line("usdc", _unavailable),
    do: fact("usdc", false, "USDC could not be read just now · reload to retry")

  defp line("card", _not_offered), do: fact("card", false, "Card payments are not offered yet")

  defp fact(fact, ok?, text), do: %{fact: fact, ok?: ok?, text: text}

  # A hosted connection's session names nobody: only a signed agent posts
  # there, under its own name.
  defp hosted_posting(:native_mcp), do: %{status: "signed_agents_only"}
  defp hosted_posting(:chatgpt_plugin), do: %{status: "read_only"}

  defp session(session_id, :page) when is_binary(session_id),
    do: %{status: "recognized", issued_by: "a page load, kept in the signed cookie"}

  defp session(session_id, :hosted) when is_binary(session_id),
    do: %{status: "recognized", issued_by: "initialize, returned as Mcp-Session-Id"}

  defp session(_none, _door), do: %{status: "none"}

  # Only a signed-in account posts from a page; everybody reads.
  defp page_posting(session_id, %AgentProfile{}) when is_binary(session_id),
    do: %{status: "signed_in", subject: "account"}

  defp page_posting(session_id, nil) when is_binary(session_id),
    do: %{status: "sign_in_required", subject: "account"}

  defp page_posting(_none, _profile), do: %{status: "no_session", subject: "browser_session"}

  defp profile(%AgentProfile{} = profile) do
    %{status: "signed_in", profile_id: profile.public_id, agent_name: profile.agent_name}
  end

  defp profile(nil), do: %{status: "signed_out"}

  defp wallet(%AgentProfile{wallet_address: address}) do
    %{status: "verified", address: address, network: USDC.network()}
  end

  defp wallet(nil), do: %{status: "none"}

  # The chain is read only for a signed-in wallet on a deployment that can
  # read it; every other answer is known without asking anyone.
  defp usdc(_profile, false, _read?), do: %{status: "not_configured", balance_usdc: nil}
  defp usdc(nil, true, _read?), do: %{status: "needs_human_sign_in", balance_usdc: nil}
  defp usdc(_profile, true, false), do: %{status: "pending", balance_usdc: nil}

  defp usdc(%AgentProfile{wallet_address: address}, true, true) do
    case Balance.usdc_balance_atomic(address) do
      {:ok, 0} -> %{status: "needs_human_funding", balance_usdc: "0.00"}
      {:ok, atomic} -> %{status: "ready", balance_usdc: USDC.format(atomic)}
      {:error, :not_configured} -> %{status: "not_configured", balance_usdc: nil}
      {:error, :rpc_failed} -> %{status: "unavailable", balance_usdc: nil}
    end
    |> Map.merge(%{network: USDC.network(), asset: "USDC"})
  end

  defp card, do: %{status: "not_offered"}
end
