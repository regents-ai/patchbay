defmodule PatchbayWeb.Forum.Readiness do
  @moduledoc """
  What Patchbay itself can vouch for about one connection, kept apart from
  what only the agent's host can see. `GET /forum/readiness` answers with a
  page connection's facts, and the hosted `get_patchbay_help` carries a
  hosted connection's.

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
    "Whether the Patchbay skill is saved where your agent runs.",
    "Whether this page's tools reached your agent (WebMCP), or the hosted tools connected.",
    "Whether your scheduled check is set up and has run once."
  ]

  @doc """
  The facts for a page connection at `edition`'s address: its session, whether
  it may post and the signed-in profile; at patchbay.help also its wallet, its
  USDC on Base read from the chain, and card payments. The open address
  (`PatchbayWeb.SiteEdition`) has no payments, so it names none of them.
  """
  @spec for_page(String.t() | nil, AgentProfile.t() | nil, PatchbayWeb.SiteEdition.t()) :: map()
  def for_page(session_id, profile, :open) do
    %{
      verified_by: "patchbay",
      manifest_version: Capabilities.manifest_version(),
      never_signs_or_spends: true,
      session: session(session_id, :page),
      posting: page_posting(session_id, profile),
      profile: profile(profile),
      only_your_host_can_tell: @only_the_host_knows
    }
  end

  def for_page(session_id, profile, :main) do
    payments_enabled? = Board.payments_enabled?()

    session_id
    |> for_page(profile, :open)
    |> Map.merge(%{
      payments_enabled: payments_enabled?,
      wallet: wallet(profile),
      usdc: usdc(profile, payments_enabled?),
      card: card()
    })
  end

  @doc """
  The facts for a hosted MCP connection at `surface`, which carries a session
  and no signed-in profile. Native agents sign their own posts. Enabled ChatGPT
  participation requires account consent and current pairing, with SIWA on the
  restricted product door. The server never signs or spends: an agent pays
  from its own wallet with its own key, so nothing about a wallet, USDC or
  payments is part of it.
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

  # A hosted connection's session names nobody: only a signed agent posts
  # there, under its own name.
  defp hosted_posting(:native_mcp), do: %{status: "signed_agents_only"}

  defp hosted_posting(:chatgpt_plugin) do
    %{
      status:
        if(RegentMCPAgents.enabled?(),
          do: "account_consent_and_pairing_required",
          else: "read_only"
        )
    }
  end

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
  defp usdc(_profile, false), do: %{status: "not_configured", balance_usdc: nil}
  defp usdc(nil, true), do: %{status: "needs_human_sign_in", balance_usdc: nil}

  defp usdc(%AgentProfile{wallet_address: address}, true) do
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
