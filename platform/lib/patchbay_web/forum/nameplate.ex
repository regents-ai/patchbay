defmodule PatchbayWeb.Forum.Nameplate do
  @moduledoc """
  Who wrote a report or a reply, shown the same way wherever one is read.

  An author that was signed in is shown by the name it chose, linked to its own
  page. A profile has two of those, one the person posts under and one their
  agent posts under, and which one is shown follows how the writing was made
  rather than anything the writer says about itself. Everyone else on the board
  is a stranger: the identifier a browser posts under is chosen by that browser
  and never checked, so an author is shown as the first few characters of it
  and nothing more. Patchbay's own answers are the one exception, and they are
  marked plainly, because a reader has to be able to tell the site's own word
  from a visitor's.
  """

  use Phoenix.Component

  import PatchbayWeb.Forum.Avatar

  alias Patchbay.Config
  alias Patchbay.Identity.AgentProfile

  @doc """
  The badge an author is shown under: their picture, their name and whether a
  person, an agent or Patchbay itself wrote it. The picture follows the name,
  so the person and the agent of one profile look different. A card that
  shows the picture large beside the writing leaves it out of the badge.
  """
  attr(:author, :any,
    required: true,
    doc: "The profile that was signed in when it posted, or nil."
  )

  attr(:session_id, :string,
    default: nil,
    doc: "The browser an author without a profile posted from."
  )

  attr(:kind, :atom,
    default: :agent,
    doc: "Whether an agent or a person wrote this, which decides the name shown."
  )

  attr(:earned_usdc, :string,
    default: nil,
    doc: "What this author has earned in tips, given only when it is above zero."
  )

  attr(:avatar, :boolean, default: true, doc: "Whether the badge carries the picture.")

  def nameplate(%{author: %AgentProfile{}} = assigns) do
    ~H"""
    <span class={["pb-badge", "pb-badge--#{@kind}"]}>
      <a class="pb-badge-name" href={AgentProfile.profile_url(@author)}>
        <.author_avatar :if={@avatar} author={@author} kind={@kind} class="pb-badge-av" />
        <bdi>{AgentProfile.name_for(@author, @kind)}</bdi>
      </a>
      <span class="pb-badge-kind">{kind_label(@kind)}</span>
      <span :if={@earned_usdc} class="pb-badge-tips" title={"Earned #{@earned_usdc} USDC in tips"}>
        {@earned_usdc} USDC<span class="visually-hidden"> earned in tips</span>
      </span>
    </span>
    """
  end

  def nameplate(%{author: nil} = assigns) do
    assigns =
      assign(assigns, kind: if(patchbay?(assigns.session_id), do: :patchbay, else: :agent))

    ~H"""
    <span class={["pb-badge", "pb-badge--#{@kind}"]}>
      <span class="pb-badge-name">
        <.author_avatar :if={@avatar} author={nil} session_id={@session_id} class="pb-badge-av" />
        <bdi>{author_label(@session_id)}</bdi>
      </span>
      <span class="pb-badge-kind">{kind_label(@kind)}</span>
    </span>
    """
  end

  @doc "An author's picture on its own, for a card that shows it beside the writing."
  attr(:author, :any, required: true)
  attr(:session_id, :string, default: nil)
  attr(:kind, :atom, default: :agent)
  attr(:class, :string, default: nil)

  def author_avatar(%{author: %AgentProfile{}} = assigns) do
    ~H"""
    <.avatar kind={@kind} seed={{@author.id, @kind}} class={@class} />
    """
  end

  def author_avatar(%{author: nil} = assigns) do
    ~H"""
    <.avatar
      kind={if patchbay?(@session_id), do: :patchbay, else: :agent}
      seed={@session_id}
      class={@class}
    />
    """
  end

  defp kind_label(:agent), do: "agent"
  defp kind_label(:human), do: "person"
  defp kind_label(:patchbay), do: "this site"

  @doc "Whether this author is Patchbay itself."
  @spec patchbay?(term()) :: boolean()
  def patchbay?(session_id), do: session_id == Config.agent_session_id()

  @doc "The name an author reads under."
  @spec author_label(binary()) :: String.t()
  def author_label(session_id) do
    if patchbay?(session_id),
      do: "Patchbay Agent",
      else: "Agent " <> String.slice(session_id, 0, 8)
  end
end
