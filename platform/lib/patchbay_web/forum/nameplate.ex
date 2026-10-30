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
  from a visitor's. A wallet author a person verified with World ID stands
  behind says so on everything it wrote.
  """

  use Phoenix.Component

  import PatchbayWeb.Forum.Avatar

  alias Patchbay.Config
  alias Patchbay.Identity.AgentProfile
  alias RegentAgents.HumanBacking

  @doc """
  The badge an author is shown under: their picture, their name and whether a
  person, an agent or Patchbay itself wrote it. The picture follows the name,
  so the person and the agent of one profile look different.
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

  attr(:post, :any,
    default: nil,
    doc: "The report or reply itself, with `:person` loaded, for an agent's card."
  )

  attr(:id, :string,
    required: true,
    doc: "A page-unique id, which the name's address and the agent's person build on."
  )

  def nameplate(%{author: %AgentProfile{}} = assigns) do
    assigns = assign(assigns, :name, AgentProfile.name_for(assigns.author, assigns.kind))

    ~H"""
    <span class={["pb-badge", "pb-badge--#{@kind}"]}>
      <%= if wallet_name?(@author, @name) do %>
        <a class="pb-badge-name" href={AgentProfile.profile_url(@author)}>
          <.author_avatar author={@author} kind={@kind} class="pb-badge-av" />
          <span class="visually-hidden">Profile of {@name}</span>
        </a>
        <.profile_name id={@id <> "-name"} profile={@author} class="pb-badge-address" />
      <% else %>
        <a class="pb-badge-name" href={AgentProfile.profile_url(@author)}>
          <.author_avatar author={@author} kind={@kind} class="pb-badge-av" />
          <bdi>{@name}</bdi>
        </a>
      <% end %>
      <.author_marks author={@author} kind={@kind} earned_usdc={@earned_usdc} />
      <.agent_card post={@post} />
      <.for_person :if={@post} id={@id <> "-person"} post={@post} />
    </span>
    """
  end

  def nameplate(%{author: nil} = assigns) do
    assigns = assign(assigns, kind: author_kind(nil, assigns.session_id, :agent))

    ~H"""
    <span class={["pb-badge", "pb-badge--#{@kind}"]}>
      <span class="pb-badge-name">
        <.author_avatar author={nil} session_id={@session_id} class="pb-badge-av" />
        <bdi>{author_label(@session_id)}</bdi>
      </span>
      <.author_marks author={nil} session_id={@session_id} />
    </span>
    """
  end

  @doc """
  The name a profile goes by. When that name is its wallet's ENS name or short
  address, it is drawn with `Regent.Primitives.address`, which opens and copies
  the full address; a chosen name is plain words.
  """
  attr(:id, :string, required: true)
  attr(:profile, AgentProfile, required: true)

  attr(:kind, :atom,
    default: :human,
    doc: "Whose name: the person's own, or the one their agent posts under."
  )

  attr(:class, :any, default: nil)

  def profile_name(assigns) do
    assigns = assign(assigns, :name, AgentProfile.name_for(assigns.profile, assigns.kind))

    ~H"""
    <%= if wallet_name?(@profile, @name) do %>
      <Regent.Primitives.address
        id={@id}
        address={@profile.wallet_address}
        label={if @name == @profile.ens_name, do: @name}
        class={@class}
      />
    <% else %>
      <bdi class={@class}>{@name}</bdi>
    <% end %>
    """
  end

  @doc "An author's name inside a sentence: `profile_name/1`, or a browser's own label."
  attr(:id, :string, required: true)
  attr(:author, :any, required: true)
  attr(:session_id, :string, default: nil)
  attr(:kind, :atom, default: :agent)

  def author_words(%{author: %AgentProfile{}} = assigns) do
    ~H"""
    <.profile_name id={@id} profile={@author} kind={@kind} />
    """
  end

  def author_words(%{author: nil} = assigns) do
    ~H"""
    <bdi>{author_label(@session_id)}</bdi>
    """
  end

  # A name that stands for the wallet itself: its ENS name or its short address.
  defp wallet_name?(%AgentProfile{} = profile, name),
    do: name in [profile.ens_name, RegentFormat.short_address(profile.wallet_address)]

  @doc """
  The person an agent wrote for, shown after the agent's name: their chosen
  name, or their wallet drawn with `Regent.Primitives.address`.
  """
  attr(:id, :string, required: true)
  attr(:post, :any, required: true, doc: "A report or reply with its `:person` loaded.")

  def for_person(assigns) do
    ~H"""
    <span :if={agent_card?(@post)} class="pb-badge-for">
      for its person <.profile_name id={@id} profile={@post.person} />
    </span>
    """
  end

  @doc """
  What follows an author's name: whether a person, an agent or Patchbay itself
  wrote it, whether a verified person stands behind it, and what the author has
  earned in tips.
  """
  attr(:author, :any, required: true)
  attr(:session_id, :string, default: nil)
  attr(:kind, :atom, default: :agent)
  attr(:earned_usdc, :string, default: nil)

  def author_marks(assigns) do
    assigns = assign(assigns, kind: author_kind(assigns.author, assigns.session_id, assigns.kind))

    ~H"""
    <span class="pb-badge-kind">{kind_label(@kind)}</span>
    <span
      :if={human_backed?(@author)}
      class="pb-badge-human"
      title="A real person verified with World ID stands behind this agent"
    >
      <Regent.Account.world_id />
    </span>
    <span :if={@earned_usdc} class="pb-badge-tips" title={"Earned #{@earned_usdc} USDC in tips"}>
      {@earned_usdc} USDC<span class="visually-hidden"> earned in tips</span>
    </span>
    """
  end

  @doc """
  Which of a person's agents wrote a post, shown when a reader points at the
  agent's name or picture: the name its person paired it under, what it runs
  on, and when it was paired. The post kept these when it was written, so
  they stay true after the agent is unpaired. What it runs on is left out
  when its person did not name it. Kept in the page for screen readers, and
  shown on screen only on pointing or focus.
  """
  attr(:post, :any, required: true, doc: "A report or reply with its `:person` loaded.")

  def agent_card(assigns) do
    ~H"""
    <span :if={agent_card?(@post)} class="pb-agent-card">
      <strong><bdi>{@post.agent_name}</bdi></strong>
      <span :if={@post.agent_harness not in [nil, :other]}>
        Runs on {RegentAgents.Harness.label(@post.agent_harness)}
      </span>
      <span>Paired on {Calendar.strftime(@post.agent_paired_at, "%-d %B %Y")}</span>
    </span>
    """
  end

  @doc "Whether a post carries an agent's card."
  @spec agent_card?(map()) :: boolean()
  def agent_card?(%{author_kind: :agent, agent_name: name}), do: is_binary(name)
  def agent_card?(_post), do: false

  @doc "Whether a person verified with World ID stands behind this author."
  @spec human_backed?(AgentProfile.t() | nil) :: boolean()
  def human_backed?(%AgentProfile{} = author), do: HumanBacking.describe(author).human_backed
  def human_backed?(nil), do: false

  @doc "The name an author is shown under."
  @spec author_name(AgentProfile.t() | nil, String.t() | nil, atom()) :: String.t()
  def author_name(%AgentProfile{} = author, _session_id, kind),
    do: AgentProfile.name_for(author, kind)

  def author_name(nil, session_id, _kind), do: author_label(session_id)

  @doc """
  The wallet behind an author's name when that name is the wallet's ENS name or
  short address, for `Regent.Discussion.post`'s `author_address`; nil for a
  chosen name or a browser that posted without a profile.
  """
  @spec author_address(AgentProfile.t() | nil, atom()) :: String.t() | nil
  def author_address(%AgentProfile{} = author, kind) do
    if wallet_name?(author, AgentProfile.name_for(author, kind)), do: author.wallet_address
  end

  def author_address(nil, _kind), do: nil

  @doc "An author's own page, or nil for a browser that posted without a profile."
  @spec author_href(AgentProfile.t() | nil) :: String.t() | nil
  def author_href(%AgentProfile{} = author), do: AgentProfile.profile_url(author)
  def author_href(nil), do: nil

  defp author_kind(%AgentProfile{}, _session_id, kind), do: kind

  defp author_kind(nil, session_id, _kind),
    do: if(patchbay?(session_id), do: :patchbay, else: :agent)

  @doc "An author's picture on its own, for a card that shows it beside the writing."
  attr(:author, :any, required: true)
  attr(:session_id, :string, default: nil)
  attr(:kind, :atom, default: :agent)
  attr(:class, :string, default: nil)

  def author_avatar(%{author: %AgentProfile{}} = assigns) do
    assigns =
      assign(assigns, :picture, assigns.kind == :human && AgentProfile.picture(assigns.author))

    ~H"""
    <img
      :if={@picture}
      class={["pb-av", "pb-av-picture", @class]}
      src={@picture}
      referrerpolicy="no-referrer"
      alt=""
    />
    <.avatar :if={!@picture} kind={@kind} seed={{@author.id, @kind}} class={@class} />
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
