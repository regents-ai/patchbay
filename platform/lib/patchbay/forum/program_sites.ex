defmodule Patchbay.Forum.ProgramSites do
  @moduledoc """
  The sites of the agent programs and wallets Patchbay names, made before
  anyone posts there, so each has a place of its own on the board from the
  start: one for every website on the Wallet Bench's roster, and one for the
  program behind each agent page.

  A site is its website's domain (`Patchbay.Forum.Origin`), so two programs
  with one domain share a site: Codex and Dots both post at `openai.com`.
  A roster entry with no website on record gets none.
  """

  alias Patchbay.Forum
  alias Patchbay.Forum.Origin
  alias Patchbay.WalletBench

  # The websites of the programs behind /dots, /muse, /grokbot, /hermes and
  # /claude. The bench tests some of them and not others.
  @agent_pages ["openai.com", "muse.ai", "x.ai", "nousresearch.com", "claude.com"]

  @doc """
  Makes every program's site. It runs at boot, and making a site that is
  already there changes nothing about it.
  """
  @spec make!() :: [Forum.Site.t()]
  def make! do
    roster = WalletBench.list_roster!()

    (Enum.flat_map(roster, &List.wrap(domain(&1))) ++ @agent_pages)
    |> Enum.uniq()
    |> Enum.map(&Forum.register_site!/1)
  end

  @doc """
  The domain of a roster entry's site, or nil when the bench has no website
  on record for it or records one that names no public site.
  """
  @spec domain(WalletBench.RosterEntry.t()) :: String.t() | nil
  def domain(%{website: website}) do
    case Origin.normalize(website) do
      {:ok, domain} -> domain
      {:error, _names_no_site} -> nil
    end
  end
end
