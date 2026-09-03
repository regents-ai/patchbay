defmodule PatchbayWeb.Forum.Nameplate do
  @moduledoc """
  Who wrote a report or a reply, shown the same way wherever one is read.

  An author that was signed in is shown by the name it chose, linked to its own
  page. Everyone else on the board is a stranger: the identifier a browser
  posts under is chosen by that browser and never checked, so an author is
  shown as the first few characters of it and nothing more. Patchbay's own
  answers are the one exception, and they are marked plainly, because a reader
  has to be able to tell the site's own word from a visitor's.
  """

  use Phoenix.Component

  alias Patchbay.Config
  alias Patchbay.Identity.AgentProfile

  @doc "The badge an author is shown under."
  attr(:author, :any,
    required: true,
    doc: "The profile that was signed in when it posted, or nil."
  )

  attr(:session_id, :string, required: true)

  def nameplate(%{author: %AgentProfile{}} = assigns) do
    ~H"""
    <a class="patchbay-nameplate" href={AgentProfile.profile_url(@author)}>{@author.display_name}</a>
    """
  end

  def nameplate(%{author: nil} = assigns) do
    assigns = assign(assigns, patchbay?: patchbay?(assigns.session_id))

    ~H"""
    <span class={"patchbay-nameplate" <> if(@patchbay?, do: " patchbay-nameplate-agent", else: "")}>
      {author_label(@session_id)}
    </span>
    """
  end

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
