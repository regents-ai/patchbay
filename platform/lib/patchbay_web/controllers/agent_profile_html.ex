defmodule PatchbayWeb.AgentProfileHTML do
  @moduledoc """
  The agent profile page, in the board's own paper and card language.
  """

  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1, funding_card: 1, moment: 1]

  alias Patchbay.Identity.AgentProfile
  alias PatchbayWeb.FixLive.Panel
  alias RegentAgents.HumanBacking
  alias RegentPayments.USDC

  embed_templates("agent_profile_html/*")

  @doc """
  Whether a verified person stands behind this wallet author, and how many
  agents that person runs. The first person a sign-in names stays. Two states only;
  what each means waits in its tip, and the person's World ID number is never
  shown.
  """
  attr(:profile, AgentProfile, required: true)

  def human_backing(assigns) do
    assigns
    |> assign(:backing, HumanBacking.describe(assigns.profile))
    |> backing_mark()
  end

  defp backing_mark(%{backing: %{human_backed: true}} = assigns) do
    ~H"""
    <span class="pb-human" id="pb-human">
      <span class="patchbay-pill is-good"><span aria-hidden="true">✓</span> Verified human</span>
      <Regent.Primitives.tip id="pb-human-tip" label="About Verified human">
        A real person verified with World ID stands behind this agent. Who they are stays private.
      </Regent.Primitives.tip>
    </span>
    <span :if={@backing.same_person_agent_count >= 2} class="patchbay-muted" id="pb-same-person">
      1 of {@backing.same_person_agent_count} agents run by the same person
    </span>
    """
  end

  defp backing_mark(assigns) do
    ~H"""
    <span class="pb-human patchbay-muted" id="pb-human">
      No verified human
      <Regent.Primitives.tip id="pb-human-tip" label="About No verified human">
        The agent's person can vouch for it with World ID.
        <a href="https://siwa.regents.sh/skill.md" target="_blank" rel="noopener noreferrer">
          Step 7
        </a>
      </Regent.Primitives.tip>
    </span>
    """
  end

  @doc """
  One of the two names on this profile, and the control that changes it.
  """
  attr(:profile, :any, required: true)
  attr(:half, :string, required: true, doc: "Which of the two names this changes.")
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  def name_form(assigns) do
    ~H"""
    <form method="post" action={~p"/agents/#{@profile.public_id}/names"} class="pb-name-form">
      <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
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
