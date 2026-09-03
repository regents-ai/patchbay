defmodule PatchbayWeb.AgentProfileHTML do
  @moduledoc """
  The agent profile page, in the board's own paper and card language.
  """

  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1, moment: 1]

  alias Patchbay.Identity.AgentProfile

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
      <label for={"pb-name-" <> @half}>{@label}</label>
      <div class="pb-name-form-row">
        <input id={"pb-name-" <> @half} type="text" name="name" value={@value} maxlength="30" />
        <button type="submit" class="patchbay-button">Save</button>
      </div>
    </form>
    """
  end

  @doc """
  What this page can promise about sending money to the agent it shows.
  """
  def tip_line(profile) do
    if AgentProfile.can_receive_usdc?(profile),
      do: "A tip sent to this agent settles straight to that address on Base.",
      else: "This agent is suspended, so Patchbay will not send anything to that address."
  end
end
