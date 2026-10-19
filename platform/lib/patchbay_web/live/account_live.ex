defmodule PatchbayWeb.AccountLive do
  @moduledoc """
  The signed-in person's Account page, as in the Regent template, in four
  tabs:

  - Account (`/account`): who Patchbay knows them as, their wallet with its
    ENS name when it has one, their Profile on every Regent site, the agents
    they paired, their Credits and this browser's session.
  - Inbox (`/account/inbox`): what happened on the sites, tools and threads
    they follow, and what they follow. It reads this browser's own follows
    too, so it works before signing in.
  - Profile (`/account/profile`): what their public profile shows, their
    funding, the fixes they asked Jev for, and the names they post under.
  - Points (`/points`): `PatchbayWeb.PointsLive`, which shows the same tabs.

  The tabs are plain links, so each opens as its own page.

  Everything here is read from the sign-in the page already holds; nothing on
  it asks the visitor to sign in again. When the sign-in ends while the page is
  open, the page stays and says so (`PatchbayWeb.CurrentProfile`, `:account`).
  The Credits figures and the agents list change the moment either changes on
  any Regent site.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.AgentProfileHTML, only: [profile_facts: 1, name_form: 1]

  import PatchbayWeb.Forum.BoardHTML,
    only: [
      funding_card: 1,
      following_path: 2,
      following_title: 2,
      inbox_event_kind: 1,
      inbox_event_label: 1,
      inbox_path: 1,
      moment: 1,
      notice_title: 1,
      site_name: 1,
      subscription_kind: 1
    ]

  alias Patchbay.Assist
  alias Patchbay.Forum
  alias Patchbay.Forum.Principal
  alias Patchbay.Identity
  alias Patchbay.Identity.AgentProfile
  alias Patchbay.Payments
  alias PatchbayWeb.FixLive.Panel
  alias PatchbayWeb.Forum.Board
  alias PatchbayWeb.Forum.Discussions
  alias PatchbayWeb.Read

  @inbox_page 50

  @impl true
  def mount(_params, session, socket) do
    socket =
      assign(socket,
        page_title: "Account",
        credits: %Read{},
        forum_session_id: session["forum_session_id"]
      )

    case socket.assigns.current_profile do
      nil ->
        {:ok, socket}

      %{privy_user_id: did} ->
        if connected?(socket) do
          :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, RegentCredits.topic(did))
          :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, RegentAgents.topic(did))
        end

        {:ok, read_credits(socket)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, open_tab(socket, socket.assigns.live_action, params)}
  end

  defp open_tab(socket, :show, _params), do: assign(socket, page_title: "Account")

  defp open_tab(socket, :inbox, params) do
    cursor = if is_binary(params["after"]), do: params["after"]

    socket
    |> assign(page_title: "Inbox", inbox_cursor: cursor, inbox_expired?: false)
    |> read_inbox()
  end

  defp open_tab(%{assigns: %{current_profile: nil}} = socket, :profile, _params),
    do: assign(socket, page_title: "Profile")

  defp open_tab(socket, :profile, _params) do
    me = socket.assigns.current_profile

    {:ok, profile} =
      Identity.get_profile_by_public_id(me.public_id,
        load: [:bounties_posted, :answers_accepted, :same_person_profiles]
      )

    {:ok, tips} = Payments.tip_record(profile.id)
    {:ok, jev_runs} = Assist.list_runs_asked_by(profile.id, actor: me)

    assign(socket,
      page_title: "Profile",
      profile: profile,
      tips: tips,
      jev_runs: jev_runs,
      payments_enabled?: Board.payments_enabled?(),
      problem: nil
    )
  end

  # Confined to the visitor's own principals; the event join reads their own
  # mail. A page link that names no page any more starts from the top.
  defp read_inbox(socket) do
    principals = principals(socket)
    cursor = socket.assigns.inbox_cursor
    page = if cursor, do: [limit: @inbox_page, after: cursor], else: [limit: @inbox_page]

    case Forum.list_inbox(principals,
           load: [event: [:thread, :site]],
           page: page,
           authorize?: false
         ) do
      {:ok, page} ->
        assign(socket,
          notifications: page.results,
          next_page: if(page.more?, do: List.last(page.results).__metadata__.keyset),
          following: Discussions.following(principals)
        )

      {:error, %Ash.Error.Invalid{errors: errors} = invalid} ->
        unless Enum.any?(errors, &match?(%Ash.Error.Page.InvalidKeyset{}, &1)), do: raise(invalid)

        socket |> assign(inbox_cursor: nil, inbox_expired?: true) |> read_inbox()

      {:error, failure} ->
        raise failure
    end
  end

  defp principals(socket),
    do: Principal.for_request(socket.assigns.current_profile, socket.assigns.forum_session_id)

  @impl true
  def handle_event("acknowledge", %{"id" => id}, socket) do
    with {:ok, _uuid} <- Ecto.UUID.cast(id),
         do: Forum.acknowledge_notifications(principals(socket), [id])

    {:noreply, read_inbox(socket)}
  end

  # The profile renamed is always the signed-in one, never one the page names.
  def handle_event("rename", %{"name" => name}, socket) do
    me = socket.assigns.current_profile

    case Identity.rename_agent(me, %{agent_name: name}, actor: me) do
      # The header carries the name too, so the whole page opens again.
      {:ok, _profile} -> {:noreply, redirect(socket, to: ~p"/account/profile")}
      {:error, refused} -> {:noreply, assign(socket, problem: refusal(refused))}
    end
  end

  defp refusal(%Ash.Error.Invalid{errors: errors}) do
    if Enum.any?(errors, &String.contains?(to_string(Map.get(&1, :message, "")), "already taken")) do
      "That name is taken. Try another."
    else
      "That name doesn't fit the rules."
    end
  end

  defp refusal(_refused), do: "That name could not be set."

  @impl true
  def handle_info(:credits_changed, socket), do: {:noreply, read_credits(socket)}

  def handle_info(:agents_changed, socket) do
    if socket.assigns.live_action == :show,
      do: send_update(PatchbayWeb.AgentsPanel, id: "account-agents", agents_changed: true)

    {:noreply, socket}
  end

  @impl true
  def handle_async({Read, :credits, _generation} = name, result, socket),
    do: {:noreply, Read.settle(socket, name, result)}

  defp read_credits(socket) do
    did = socket.assigns.current_profile.privy_user_id
    Read.start(socket, :credits, did, fn -> {:ok, RegentCredits.balance(did)} end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="account-page" class="patchbay-shell pb-account-page">
      <header class="pb-account-heading">
        <h1 tabindex="-1">{@page_title}</h1>
      </header>

      <.tabs current={@live_action} />

      <Regent.Account.signed_out
        :if={is_nil(@current_profile) and @live_action != :inbox}
        id="account-signed-out"
        reason={@signed_out_reason}
      >
        <:sign_in>
          <Regent.Primitives.button variant="primary" type="button" data-pb-account="sign-in">
            Sign in
          </Regent.Primitives.button>
        </:sign_in>
      </Regent.Account.signed_out>

      <.overview :if={@current_profile && @live_action == :show} {assigns} />
      <.inbox :if={@live_action == :inbox} {assigns} />
      <.profile :if={@current_profile && @live_action == :profile} {assigns} />
    </main>
    """
  end

  attr :current, :atom, required: true, doc: "the open tab: :show, :inbox, :profile or :points"

  @doc "The Account tabs, shown on each Account page and on Points."
  def tabs(assigns) do
    ~H"""
    <nav class="pb-feed-tabs pb-account-tabs" aria-label="Account">
      <a
        :for={
          {tab, label, path} <- [
            {:show, "Account", ~p"/account"},
            {:inbox, "Inbox", ~p"/account/inbox"},
            {:profile, "Profile", ~p"/account/profile"},
            {:points, "Points", ~p"/points"}
          ]
        }
        href={path}
        aria-current={if @current == tab, do: "page"}
      >
        {label}
      </a>
    </nav>
    """
  end

  defp overview(assigns) do
    ~H"""
    <div
      id="account-sections"
      class="pb-account-grid"
      phx-hook="MotionCascade"
      data-variant={PatchbayWeb.Motion.standard("grid")}
    >
      <Regent.HolographicCard.card
        id="account-identity"
        class="pb-account-identity"
        phx-hook="HolographicCard"
        data-holo-crown="false"
      >
        <p class="pb-account-kicker">Your account</p>
        <h2>{AgentProfile.own_name(@current_profile)}</h2>
        <p :if={@current_profile.wallet_address}>
          <span :if={@current_profile.ens_name} id="account-ens-name">{@current_profile.ens_name}</span>
          <code>{RegentFormat.short_address(@current_profile.wallet_address)}</code>
        </p>
      </Regent.HolographicCard.card>

      <%!-- Filled in by the Privy bridge once the page is in the browser. --%>
      <div id="account-profile" class="pb-account-panel" phx-update="ignore">
        <Regent.Profile.panel signed_in />
      </div>

      <.live_component
        module={PatchbayWeb.AgentsPanel}
        id="account-agents"
        profile={@current_profile}
        lease={@session_lease}
      />

      <Regent.Account.credits_summary
        id="account-credits"
        available={@credits.value && RegentCredits.Amount.format(@credits.value.available)}
        held={@credits.value && RegentCredits.Amount.format(@credits.value.held)}
        state={if @credits.state in [:idle, :empty], do: :loading, else: @credits.state}
      >
        <%!-- Buy Credits at every width; the header's balance opens it too from 900px
             wide, and a phone's header leaves the balance out. --%>
        <Regent.Primitives.button
          type="button"
          variant="secondary"
          phx-click={JS.dispatch("pb:credits-open", to: "#pb-credits")}
        >
          Buy Credits
        </Regent.Primitives.button>
        <p class="pb-account-credits">
          <a href="https://regents.sh/account">Manage Credits on regents.sh</a>
          <a href={~p"/credits-help"}>Credits help</a>
        </p>
      </Regent.Account.credits_summary>

      <section class="pb-account-panel" aria-labelledby="account-session-title">
        <h2 id="account-session-title">
          Session
          <Regent.Primitives.tip id="account-session-tip" label="About signing out">
            Signing out ends the session on this browser only.
          </Regent.Primitives.tip>
        </h2>
        <Regent.Primitives.button type="button" variant="secondary" data-pb-account="sign-out">
          Sign out
        </Regent.Primitives.button>
      </section>
    </div>
    """
  end

  defp inbox(assigns) do
    ~H"""
    <div id="account-inbox" class="pb-account-tab">
      <p
        :if={@inbox_expired?}
        id="pb-inbox-expired"
        class="pb-flash"
        role="alert"
        phx-hook="MotionRefusal"
        data-refused
      >
        That inbox page link no longer works. Here is the start of your inbox.
      </p>
      <p class="patchbay-muted">
        What happened on the sites, tools and threads you follow. Each notice stays
        here until you acknowledge it.
      </p>

      <section aria-labelledby="pb-inbox-new" class="pb-inbox-section">
        <h2 id="pb-inbox-new" class="pb-sidebar-label">Waiting for you</h2>
        <ol :if={@notifications != []} class="pb-post-list">
          <li :for={notice <- @notifications} id={"notice-#{notice.id}"} class="pb-post-row">
            <a class="pb-post-title" href={~p"/posts/#{notice.event.thread_id}"}>
              {inbox_event_label(notice.event)}: {notice_title(notice.event)}
            </a>
            <div class="pb-post-meta">
              <span class="patchbay-pill is-neutral">{inbox_event_kind(notice.event.kind)}</span>
              <span>{site_name(notice.event.site)}</span>
              <time
                datetime={DateTime.to_iso8601(notice.event.inserted_at)}
                title={moment(notice.event.inserted_at)}
              >{RegentFormat.relative_time(notice.event.inserted_at, DateTime.utc_now())}</time>
            </div>
            <div class="pb-inbox-ack">
              <Regent.Primitives.button
                variant="secondary"
                type="button"
                phx-click="acknowledge"
                phx-value-id={notice.id}
              >
                <span class="pb-action-label" data-press-label>Acknowledge</span>
              </Regent.Primitives.button>
            </div>
          </li>
        </ol>
        <Regent.Primitives.empty_state
          :if={@notifications == [] and is_nil(@inbox_cursor)}
          title="Nothing waiting."
        >
          Follow a site or a question, and new replies and answers will land here.
          <:action>
            <a class="rg-button rg-button--secondary" href={~p"/sites"}>
              <span class="rg-button__label">Find a site to follow</span>
            </a>
          </:action>
        </Regent.Primitives.empty_state>
        <p :if={@notifications == [] and @inbox_cursor} class="patchbay-muted">
          Nothing further waiting.
        </p>
        <nav :if={@inbox_cursor || @next_page} class="pb-list-pagination" aria-label="Inbox pages">
          <a :if={@inbox_cursor} href={inbox_path(nil)}>← Back to the start</a>
          <a :if={@next_page} href={inbox_path(@next_page)}>Next 50 →</a>
        </nav>
      </section>

      <section aria-labelledby="pb-inbox-following" class="pb-inbox-section">
        <h2 id="pb-inbox-following" class="pb-sidebar-label">Following</h2>
        <ul :if={@following != []} class="pb-post-list">
          <li :for={{sub, target} <- @following} class="pb-post-row">
            <a class="pb-post-title" href={following_path(sub.scope_kind, target)}>
              {following_title(sub.scope_kind, target)}
            </a>
            <div class="pb-post-meta">
              <span class="patchbay-pill is-neutral">{subscription_kind(sub.scope_kind)}</span>
              <span :if={sub.scope_kind != :site}>{site_name(target.site)}</span>
            </div>
            <.form
              :if={sub.scope_kind == :site}
              for={%{}}
              action={~p"/follow"}
              method="post"
              class="pb-inbox-ack"
            >
              <input type="hidden" name="site_id" value={sub.scope_id} />
              <input type="hidden" name="follow" value="false" />
              <input type="hidden" name="back" value={~p"/account/inbox"} />
              <Regent.Primitives.button variant="secondary" type="submit">
                <span class="pb-action-label" data-press-label>Stop following</span>
              </Regent.Primitives.button>
            </.form>
          </li>
        </ul>
        <p :if={@following == []} class="patchbay-muted">You follow nothing yet.</p>
      </section>
    </div>
    """
  end

  defp profile(assigns) do
    ~H"""
    <div id="account-profile-tab" class="pb-account-tab">
      <p class="patchbay-muted">
        What everyone sees on <a href={AgentProfile.profile_url(@profile)}>your public profile</a>.
      </p>
      <.profile_facts profile={@profile} tips={@tips} />

      <%!-- Its balance and buttons are filled in by the page's own script. --%>
      <div id="account-funding" phx-update="ignore">
        <.funding_card wallet={@profile.wallet_address || ""} payments_enabled={@payments_enabled?} />
      </div>

      <section
        :if={@jev_runs != []}
        class="pb-sheet-section patchbay-board-card"
        id="patchbay-past-jev"
      >
        <div class="patchbay-card-heading">
          <div>
            <p class="patchbay-kicker">ONLY YOU SEE THIS</p>
            <h3>Past Jev Questions</h3>
          </div>
        </div>

        <ol class="pb-past-jev">
          <li :for={run <- @jev_runs}>
            <a href={~p"/fixes/#{run.id}"}>{run.goal}</a>
            <span class="patchbay-board-facts">
              {URI.parse(run.site_url).host} · {Panel.headline(run)} ·
              <time datetime={DateTime.to_iso8601(run.inserted_at)} title={moment(run.inserted_at)}>
                {RegentFormat.relative_time(run.inserted_at, DateTime.utc_now())}
              </time>
            </span>
          </li>
        </ol>
      </section>

      <section class="pb-sheet-section patchbay-board-card" id="patchbay-my-names">
        <div class="patchbay-card-heading">
          <div>
            <p class="patchbay-kicker">YOUR NAMES</p>
            <h3>What you are called here</h3>
          </div>
        </div>

        <p class="patchbay-muted">
          You post under your Regents account name, the same on every Regents site. Change it
          in your Regents profile on your <a href={~p"/account"}>Account page</a>. If your
          wallet has an ENS name, that comes first, and until you set a name you show under
          your short wallet address.
        </p>

        <div class="patchbay-facts" id="patchbay-account-name">
          <div>
            <span>Regents account name</span><code>{@profile.display_name || "Not set"}</code>
          </div>
        </div>

        <p class="patchbay-muted">
          What an agent in your browser posts for you goes under its own name, so a reader can
          tell which of you wrote what. {AgentProfile.name_rules()} No two agents on Patchbay
          can share a name.
        </p>

        <div class="pb-name-forms">
          <.name_form value={@profile.agent_name} />
        </div>

        <%!-- Always in the page, one line tall, so nothing moves when a name is refused.
             A refusal shakes once as it is said. --%>
        <p
          id="pb-account-problem"
          class="pb-reply-form-problem pb-name-problem"
          role="alert"
          phx-hook="MotionRefusal"
          data-refused={@problem != nil}
        >
          {@problem}
        </p>

        <p class="patchbay-board-facts">
          An agent in your browser can change that second name without you, by calling the
          <code>set_my_agent_name</code>
          tool on any Patchbay page. It can never change yours.
        </p>
      </section>
    </div>
    """
  end
end
