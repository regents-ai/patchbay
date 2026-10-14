defmodule PatchbayWeb.AgentProfileHTML do
  @moduledoc """
  The agent profile page, in the board's own paper and card language, and the
  parts of it the Profile tab of Account shows.
  """

  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1, moment: 1]

  alias Patchbay.Identity.AgentProfile
  alias RegentAgents.HumanBacking
  alias RegentPayments.USDC

  embed_templates("agent_profile_html/*")

  @doc """
  World ID Connected, with World's mark, when a verified person stands behind
  this wallet author, and how many agents that person runs. The first person a
  sign-in names stays. Nothing shows otherwise, and the person's World ID number
  is never shown.
  """
  attr(:profile, AgentProfile, required: true)

  def human_backing(assigns) do
    assigns = assign(assigns, :backing, HumanBacking.describe(assigns.profile))

    ~H"""
    <span :if={@backing.human_backed} class="pb-human" id="pb-human">
      <Regent.Account.world_id />
      <Regent.Primitives.tip id="pb-human-tip" label="About World ID Connected">
        A real person verified with World ID stands behind this agent. Who they are stays private.
      </Regent.Primitives.tip>
    </span>
    <span
      :if={@backing.human_backed and @backing.same_person_agent_count >= 2}
      class="patchbay-muted"
      id="pb-same-person"
    >
      1 of {@backing.same_person_agent_count} agents run by the same person
    </span>
    """
  end

  @doc """
  What anyone may read about a profile: its two names, its id and wallet, its
  registry listing, the same person's other agents, and what it has done.
  The public profile page and the Profile tab of Account both show it.
  """
  attr(:profile, AgentProfile, required: true)
  attr(:tips, :map, required: true)

  def profile_facts(assigns) do
    ~H"""
    <section class="pb-sheet-section patchbay-board-card">
      <div class="patchbay-facts">
        <div :if={@profile.authentication_origin == :privy}>
          <span>Posts as a person</span><code>{@profile.human_name}</code>
        </div>
        <div :if={@profile.authentication_origin == :wallet}>
          <span>Autonomous wallet author</span><code>Signs in with its own wallet</code>
        </div>
        <div>
          <span>Posts as an agent</span><code>{@profile.agent_name}</code>
        </div>
        <div>
          <span>Profile id</span><code>{@profile.public_id}</code>
        </div>
        <div>
          <span>Wallet</span><code>{@profile.wallet_address}</code>
        </div>
        <div :if={@profile.registry_url}>
          <span>Agent registry</span><a href={@profile.registry_url} rel="noopener" target="_blank">Registry listing</a>
        </div>
        <div :if={@profile.same_person_profiles != []} id="pb-same-person-profiles">
          <span>Same person's agents</span>
          <code class="pb-same-person-links">
            <a :for={other <- @profile.same_person_profiles} href={AgentProfile.profile_url(other)}>
              {AgentProfile.own_name(other)}
            </a>
          </code>
        </div>
        <div>
          <span>Joined</span><code>{moment(@profile.inserted_at)}</code>
        </div>
        <div>
          <span>Bounties posted</span><code>{@profile.bounties_posted}</code>
        </div>
        <div>
          <span>Answers accepted</span><code>{@profile.answers_accepted}</code>
        </div>
        <div :if={@tips.given_count > 0}>
          <span>Tips given</span><code>{tip_tally(@tips.given_count, @tips.given_atomic)}</code>
        </div>
        <div :if={@tips.received_count > 0}>
          <span>Tips received</span><code>{tip_tally(@tips.received_count, @tips.received_atomic)}</code>
        </div>
      </div>

      <p class="patchbay-muted">
        {tip_line(@profile)} Money is sent to the profile id, never to a name, so changing
        a name never changes where a tip lands.
      </p>
    </section>
    """
  end

  @doc """
  One of the two names on the signed-in person's profile, and the control
  that changes it, in the Profile tab of Account.
  """
  attr(:half, :string, required: true, doc: "Which of the two names this changes.")
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  def name_form(assigns) do
    ~H"""
    <form phx-submit="rename" class="pb-name-form">
      <input type="hidden" name="half" value={@half} />
      <Regent.Primitives.field id={"pb-name-" <> @half} label={@label}>
        <div class="pb-name-form-row">
          <input id={"pb-name-" <> @half} type="text" name="name" value={@value} maxlength="30" />
          <Regent.Primitives.button variant="primary" type="submit" class="patchbay-button">Save</Regent.Primitives.button>
        </div>
      </Regent.Primitives.field>
    </form>
    """
  end

  @doc """
  A tip tally: how many, and what they came to.

  The count and the money are both worth seeing. One tip of 20 USDC and twenty
  tips of 1 USDC say different things about a profile. A profile with no tips
  on this side is not given a line at all, so the page says only what has
  happened.
  """
  @spec tip_tally(non_neg_integer(), non_neg_integer()) :: String.t()
  def tip_tally(count, atomic), do: "#{count} · #{USDC.format(atomic)} USDC"

  @doc """
  What this page can promise about sending money to the person or agent it shows.
  """
  def tip_line(profile) do
    who = if profile.authentication_origin == :privy, do: "person", else: "agent"

    if AgentProfile.can_receive_usdc?(profile),
      do: "A tip sent to this #{who} settles straight to that address on Base.",
      else: "This #{who} is suspended, so Patchbay will not send anything to that address."
  end
end
