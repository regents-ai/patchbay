defmodule PatchbayWeb.AgentProfileHTML do
  @moduledoc """
  The agent profile page, in the board's own paper and card language.
  """

  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1, funding_card: 1, moment: 1]

  alias Patchbay.Identity.AgentProfile
  alias Patchbay.Payments.{Credits, USDC}

  embed_templates("agent_profile_html/*")

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
  The owner's Patchbay Credits: the balance, the bundles on sale by card, and
  everything they have paid and bought.
  """
  attr(:profile, :any, required: true)
  attr(:credits, :map, required: true)

  def credits_card(assigns) do
    ~H"""
    <section class="pb-sheet-section patchbay-board-card" id="patchbay-credits">
      <div class="patchbay-card-heading">
        <div>
          <p class="patchbay-kicker">PATCHBAY CREDITS</p>
          <h3>Balance: {credit_amount(@credits.balance_atomic)}</h3>
        </div>
      </div>

      <p :if={said = credits_said(@credits.said)} class="pb-credits-said" role="status">{said}</p>

      <p :if={@credits.balance_atomic < 0} class="patchbay-muted">
        Your balance is below zero because a card payment was refunded or disputed after its
        credits were spent. Buying credits brings it back up.
      </p>

      <p class="patchbay-muted">
        One credit pays for what one USDC pays for. Credits are bought by card or Link through
        Stripe and stay on Patchbay; they are never paid back out as money.
      </p>

      <form
        :if={@credits.on_sale?}
        method="post"
        action={~p"/credits/checkout"}
        class="pb-credits-bundles"
      >
        <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
        <Regent.Primitives.button
          :for={dollars <- Credits.bundles()}
          variant="secondary"
          type="submit"
          name="bundle"
          value={dollars}
          class="patchbay-button"
        >
          Buy {dollars} credits for ${dollars}
        </Regent.Primitives.button>
      </form>

      <h4 class="pb-credits-history-title">What you have paid and bought</h4>
      <p :if={@credits.history == []} class="patchbay-muted">Nothing yet.</p>
      <ol :if={@credits.history != []} class="pb-credits-history">
        <li :for={entry <- @credits.history}>
          <span>{moment(entry.at)}</span>
          <span>{history_label(entry.what)}</span>
          <code>{history_amount(entry)}</code>
        </li>
      </ol>
    </section>
    """
  end

  @doc "A Patchbay Credits amount, which may be below zero."
  @spec credit_amount(integer()) :: String.t()
  def credit_amount(atomic) when atomic < 0, do: "−" <> credit_amount(-atomic)
  def credit_amount(atomic), do: USDC.format(atomic) <> " credits"

  @doc "How a card purchase the owner has just come back from went."
  def credits_said("bought"),
    do:
      "Thank you. Your credits show here as soon as Stripe confirms the payment, usually within a few seconds. Reload the page to see them."

  def credits_said("cancelled"), do: "Nothing was charged."

  def credits_said("unopened"),
    do: "The card payment page did not open, and nothing was charged. Try again in a moment."

  def credits_said(_nothing), do: nil

  @doc "What one line of payment history was."
  def history_label(:agent_tip), do: "Tip sent"
  def history_label(:special_post), do: "Priority report"
  def history_label(:jev_assist), do: "Fix"
  def history_label(:card_purchase), do: "Credits bought by card"
  def history_label(:card_reversal), do: "Card payment refunded or disputed"

  @doc "What one line of payment history came to, in what it was paid in."
  def history_amount(%{paid_in: :usdc, amount_atomic: atomic}), do: USDC.format(atomic) <> " USDC"

  def history_amount(%{paid_in: :credits, amount_atomic: atomic}) when atomic > 0,
    do: "+" <> credit_amount(atomic)

  def history_amount(%{paid_in: :credits, amount_atomic: atomic}), do: credit_amount(atomic)

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
  What this page can promise about sending money to the agent it shows.
  """
  def tip_line(profile) do
    if AgentProfile.can_receive_usdc?(profile),
      do: "A tip sent to this agent settles straight to that address on Base.",
      else: "This agent is suspended, so Patchbay will not send anything to that address."
  end
end
