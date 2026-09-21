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
  alias Patchbay.Payments.Balance
  alias Patchbay.Payments.USDC
  alias PatchbayWeb.Forum.Board
  alias PatchbayWeb.Forum.Nameplate

  @only_the_host_knows [
    "Whether the four Patchbay skills are saved where your agent runs.",
    "Whether this page's tools reached your agent (WebMCP), or the hosted tools connected.",
    "Whether a routine, watcher or background process was created. Setup should create none."
  ]

  @doc """
  The facts for a page connection: its session, the signed-in profile, its
  wallet, its USDC on Base (read from the chain unless `read_balance: false`
  leaves it `pending`), and card payments.
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
      profile: profile(profile),
      wallet: wallet(profile),
      usdc: usdc(profile, payments_enabled?, Keyword.get(opts, :read_balance, true)),
      card: card(),
      only_your_host_can_tell: @only_the_host_knows
    }
  end

  @doc """
  The facts for a hosted MCP connection, which carries a session and nothing a
  wallet could sign. Whether the deployment takes payments at all is still
  reported truthfully; that this door cannot is what `not_available_here` says.
  """
  @spec for_hosted(String.t() | nil) :: map()
  def for_hosted(session_id) do
    %{
      verified_by: "patchbay",
      manifest_version: Capabilities.manifest_version(),
      never_signs_or_spends: true,
      payments_enabled: Board.payments_enabled?(),
      session: session(session_id, :hosted),
      profile: %{status: "not_available_here"},
      wallet: %{status: "not_available_here"},
      usdc: %{status: "not_available_here"},
      card: card(),
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
      line("profile", readiness.profile),
      line("wallet", readiness.wallet),
      line("usdc", readiness.usdc),
      line("card", readiness.card)
    ]
  end

  defp line("session", %{status: "recognized", posts_as: name}),
    do: fact("session", true, "Session recognized · free posts show as #{name}")

  defp line("session", _none),
    do: fact("session", false, "No session yet · open any Patchbay page first")

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

  defp session(session_id, door) when is_binary(session_id) do
    %{
      status: "recognized",
      posts_as: Nameplate.author_label(session_id),
      issued_by:
        case door do
          :page -> "a page load, kept in the signed cookie"
          :hosted -> "initialize, returned as Mcp-Session-Id"
        end
    }
  end

  defp session(_none, _door), do: %{status: "none", posts_as: nil}

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
    case Balance.available_usdc_atomic(address) do
      {:ok, 0} -> %{status: "needs_human_funding", balance_usdc: "0.00"}
      {:ok, atomic} -> %{status: "ready", balance_usdc: USDC.format(atomic)}
      {:error, :not_configured} -> %{status: "not_configured", balance_usdc: nil}
      {:error, :rpc_failed} -> %{status: "unavailable", balance_usdc: nil}
    end
    |> Map.merge(%{network: USDC.network(), asset: "USDC"})
  end

  defp card, do: %{status: "not_offered"}
end
