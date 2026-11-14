defmodule PatchbayWeb.OffersAdminLive do
  @moduledoc """
  Patchbay's own side of agent offers, at `/admin/offers`: approve or pull
  campaigns, accept or block advertiser wallets, keep pools and their
  members, choose the pools each placement shows from, and see each
  placement's live leases with how often each was shown. A stopped reading
  of the market is cleared here too.

  Every press acts in place, as the signed-in moderator: each action's own
  policy decides (`Patchbay.Checks.Moderator`), never this page. Pulling a
  campaign stops it being shown at once; its money follows the market's own
  path, which only the publisher's wallet can take, and the page names those
  steps without signing anything.

  Only a moderator reaches the page (`PatchbayWeb.Moderators`), only on
  patchbay.help and only while a market is set (`PatchbayWeb.OffersGate`).
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.AdminLinks, only: [admin_links: 1]
  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1, moment: 1]

  alias Patchbay.Offers
  alias PatchbayWeb.Read
  alias Regent.Primitives

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, Offers.topic())

    {:ok,
     socket
     |> assign(PatchbayWeb.PublicDocuments.page("/admin/offers"))
     |> assign(problem: nil, admin: %Read{})
     |> reread()}
  end

  @impl true
  def handle_info(:offers_changed, socket), do: {:noreply, reread(socket)}

  @impl true
  def handle_event("retry", _params, socket), do: {:noreply, reread(socket)}

  def handle_event("approve", %{"campaign_id" => id} = params, socket),
    do: press(socket, &Offers.approve_campaign/3, [id, %{reason: params["reason"] || ""}])

  def handle_event("pull", %{"campaign_id" => id, "reason" => reason}, socket),
    do: press(socket, &Offers.pull_campaign/3, [id, %{reason: reason}])

  def handle_event("set_rule", %{"wallet" => wallet, "verdict" => verdict}, socket)
      when verdict in ["accepted", "blocked"],
      do:
        press(socket, &Offers.set_advertiser_rule/3, [
          String.downcase(String.trim(wallet)),
          String.to_existing_atom(verdict)
        ])

  def handle_event("remove_rule", %{"id" => id}, socket),
    do: press_on(socket, &Offers.get_advertiser_rule/2, id, &Offers.remove_advertiser_rule/2)

  def handle_event("create_pool", %{"name" => name, "tags" => tags}, socket),
    do: press(socket, &Offers.create_pool/2, [%{name: String.trim(name), tags: words(tags)}])

  def handle_event("delete_pool", %{"id" => id}, socket),
    do: press_on(socket, &Offers.get_pool/2, id, &Offers.delete_pool/2)

  def handle_event("add_member", %{"pool_id" => pool_id, "wallet" => wallet}, socket),
    do: press(socket, &Offers.add_pool_member/3, [pool_id, String.downcase(String.trim(wallet))])

  def handle_event("remove_member", %{"id" => id}, socket),
    do: press_on(socket, &Offers.get_pool_member/2, id, &Offers.remove_pool_member/2)

  def handle_event("choose_pool", %{"placement_id" => placement_id, "pool_id" => pool_id}, socket) do
    choice = %{
      chain_id: Offers.chain().chain_id,
      market: Offers.market(),
      placement_id: placement_id,
      pool_id: pool_id
    }

    press(socket, &Offers.choose_pool/2, [choice])
  end

  def handle_event("drop_pool", %{"id" => id}, socket),
    do: press_on(socket, &Offers.get_placement_pool/2, id, &Offers.drop_pool/2)

  def handle_event("clear_stop", %{"next_block" => next_block}, socket) do
    %{chain_id: chain_id} = Offers.chain()
    actor = socket.assigns.current_profile

    with {:ok, cursor} <- Offers.get_cursor(chain_id, Offers.market(), actor: actor),
         {:ok, _cleared} <- Offers.clear_cursor(cursor, %{next_block: next_block}, actor: actor) do
      Offers.Watch.refresh()
      {:noreply, socket |> assign(problem: nil) |> reread()}
    else
      {:error, problem} -> {:noreply, socket |> assign(problem: refusal(problem)) |> reread()}
    end
  end

  # One action, run as the signed-in moderator; the page shows what it left.
  defp press(socket, action, args) do
    case apply(action, args ++ [[actor: socket.assigns.current_profile]]) do
      {:ok, _done} -> {:noreply, socket |> assign(problem: nil) |> reread()}
      {:error, problem} -> {:noreply, socket |> assign(problem: refusal(problem)) |> reread()}
    end
  end

  # A row is read again as the moderator before it is removed.
  defp press_on(socket, get, id, remove) do
    actor = socket.assigns.current_profile

    result =
      with {:ok, row} <- get.(id, actor: actor),
           do: remove.(row, actor: actor)

    case result do
      :ok -> {:noreply, socket |> assign(problem: nil) |> reread()}
      {:error, problem} -> {:noreply, socket |> assign(problem: refusal(problem)) |> reread()}
    end
  end

  defp reread(socket) do
    admin = socket.assigns.current_profile
    Read.now(socket, :admin, admin.id, fn -> read_admin(admin) end)
  end

  defp read_admin(admin) do
    %{chain_id: chain_id} = Offers.chain()
    market = Offers.market()

    with {:ok, campaigns} <- Offers.campaign_catalog(actor: admin, load: [:review, :reviews]),
         {:ok, rules} <- Offers.list_advertiser_rules(actor: admin),
         {:ok, pools} <- Offers.list_pools(actor: admin, load: [:members]),
         {:ok, placements} <- Offers.open_placements(chain_id, market, actor: admin),
         {:ok, leases} <-
           Offers.live_leases(chain_id, market, actor: admin, load: [:delivery_count]),
         {:ok, chosen} <-
           Offers.placement_pools(chain_id, market, Enum.map(placements, & &1.placement_id),
             actor: admin,
             load: [:pool]
           ),
         {:ok, cursor} <- Offers.get_cursor(chain_id, market, actor: admin, load: [:fresh?]) do
      leases = Enum.uniq_by(leases, &{&1.placement_id, &1.slot})

      {:ok,
       %{
         campaigns: campaigns,
         titles: Map.new(campaigns, &{&1.campaign_id, &1.title}),
         rules: Enum.sort_by(rules, & &1.wallet),
         pools: Enum.sort_by(pools, & &1.name),
         placements: placements,
         leases: Enum.group_by(leases, & &1.placement_id),
         chosen: Enum.group_by(chosen, & &1.placement_id),
         cursor: cursor
       }}
    end
  end

  # Tags typed apart by commas or spaces, as threads carry them.
  defp words(text), do: text |> String.downcase() |> String.split(~r/[\s,]+/, trim: true)

  defp refusal(%Ash.Error.Forbidden{}), do: "Only a moderator can do that."

  defp refusal(%Ash.Error.Invalid{errors: errors}),
    do: errors |> Enum.map(&said/1) |> Enum.uniq() |> Enum.join(" ")

  defp refusal(_problem), do: "That could not be saved. Try again in a moment."

  defp said(%{field: :wallet}), do: "Use a wallet address: 0x and 40 letters or digits."

  defp said(%{field: :name, message: "A pool has that name already."}),
    do: "A pool has that name."

  defp said(%{field: :name}), do: "Name the pool in 2 to 40 characters."
  defp said(%{field: :tags}), do: "Use topic tags, such as payments or auth."
  defp said(%{field: :reason}), do: "Keep the reason to 500 characters."
  defp said(%{field: :next_block}), do: "Give the block to read on from."
  defp said(_error), do: "That could not be saved. Check it and try again."

  @impl true
  def render(assigns) do
    ~H"""
    <main class="patchbay-shell patchbay-board pb-offmod pb-oa" id="pb-offers-admin">
      <.board_header>
        <:back><.admin_links current="/admin/offers" /></:back>
        <:title>Offers</:title>
        <:meta>
          <span class="patchbay-generation">Private</span>
        </:meta>
      </.board_header>

      <p
        :if={@problem}
        id="pb-oa-problem"
        class="pb-offmod-problem"
        role="alert"
        phx-hook="MotionRefusal"
        phx-remove={PatchbayWeb.Motion.leave()}
        data-refused
      >
        {@problem}
      </p>

      <p :if={@admin.state in [:stale, :error]} class="pb-offmod-problem" role="status">
        {if @admin.state == :stale,
          do: "This may be out of date: the page could not be read again.",
          else: "This page could not be loaded just now."}
        <button type="button" phx-click="retry">Try again</button>
      </p>

      <%= if admin = @admin.value do %>
        <.reading cursor={admin.cursor} />
        <.campaigns admin={admin} />
        <.advertisers rules={admin.rules} />
        <.pools pools={admin.pools} />
        <.placements admin={admin} />
      <% end %>
    </main>
    """
  end

  attr :cursor, :any, required: true

  defp reading(assigns) do
    ~H"""
    <section
      :if={@cursor && @cursor.rescan_from}
      id="pb-oa-reading"
      class="pb-sheet-section pb-oa-card"
      aria-labelledby="pb-oa-reading-title"
    >
      <h2 id="pb-oa-reading-title">Reading</h2>
      <p>
        Patchbay's record of the market disagrees with Base at block {@cursor.rescan_from}, so reading
        is stopped. Correct the record, then go on from the block it is right up to.
      </p>
      <form id="pb-oa-clear" phx-submit="clear_stop" class="pb-offmod-actions">
        <Primitives.field id="pb-oa-next-block" label="Block">
          <input
            id="pb-oa-next-block"
            type="number"
            name="next_block"
            min="0"
            value={@cursor.rescan_from}
            required
          />
        </Primitives.field>
        <Primitives.button type="submit" variant="secondary">Continue</Primitives.button>
      </form>
    </section>
    """
  end

  attr :admin, :map, required: true

  defp campaigns(assigns) do
    ~H"""
    <section id="pb-oa-campaigns" class="pb-sheet-section" aria-labelledby="pb-oa-campaigns-title">
      <h2 id="pb-oa-campaigns-title">Campaigns</h2>
      <p class="patchbay-muted">
        A campaign is shown and can be bought only once approved. Pulling it stops it everywhere at once.
      </p>

      <Primitives.empty_state
        :if={@admin.campaigns == []}
        id="pb-oa-no-campaigns"
        title="No campaigns"
      >
        Campaigns appear here as advertisers save them.
      </Primitives.empty_state>

      <ol :if={@admin.campaigns != []} class="pb-oa-list">
        <li
          :for={campaign <- @admin.campaigns}
          id={"pb-oa-campaign-#{campaign.id}"}
          class="pb-oa-row"
          data-review={campaign.review}
        >
          <div class="pb-oa-row-head">
            <a
              class="pb-oa-name"
              href={campaign.link}
              target="_blank"
              rel="noopener noreferrer nofollow"
            >
              {campaign.title}
            </a>
            <span class={["patchbay-pill", review_tone(campaign.review)]}>
              {review_label(campaign.review)}
            </span>
          </div>
          <p class="pb-oa-body">{campaign.body}</p>
          <dl class="pb-oa-facts">
            <div>
              <dt>Wallet</dt>
              <dd>
                <Primitives.address
                  id={"pb-oa-campaign-#{campaign.id}-wallet"}
                  address={campaign.advertiser}
                  variant="compact"
                />
              </dd>
            </div>
            <div :if={campaign.notes != ""}>
              <dt>Notes</dt>
              <dd>{campaign.notes}</dd>
            </div>
            <div :if={targeting(campaign) != []}>
              <dt>Shown to</dt>
              <dd>{Enum.join(targeting(campaign), " · ")}</dd>
            </div>
          </dl>

          <div :if={campaign.review != :pulled} class="pb-offmod-actions">
            <Primitives.button
              :if={campaign.review == :waiting}
              id={"pb-oa-approve-#{campaign.id}"}
              type="button"
              variant="primary"
              phx-click="approve"
              phx-value-campaign_id={campaign.campaign_id}
            >
              Approve
            </Primitives.button>
            <form
              id={"pb-oa-pull-#{campaign.id}"}
              phx-submit="pull"
              class="pb-offmod-actions pb-oa-pull"
            >
              <input type="hidden" name="campaign_id" value={campaign.campaign_id} />
              <Primitives.field id={"pb-oa-pull-why-#{campaign.id}"} label="Reason">
                <input
                  id={"pb-oa-pull-why-#{campaign.id}"}
                  type="text"
                  name="reason"
                  maxlength="500"
                  autocomplete="off"
                />
              </Primitives.field>
              <Primitives.button
                type="submit"
                variant="secondary"
                data-confirm={"Pull #{campaign.title}? It stops being shown everywhere at once."}
                data-confirm-action="Pull"
              >
                Pull
              </Primitives.button>
            </form>
          </div>

          <.refund_steps
            :if={campaign.review == :pulled}
            campaign={campaign}
            leases={@admin.leases}
            placements={@admin.placements}
          />
        </li>
      </ol>
    </section>
    """
  end

  attr :campaign, :map, required: true
  attr :leases, :map, required: true
  attr :placements, :list, required: true

  # The pulled campaign's leases still hold its money; only the publisher's
  # wallet ends their placements, and anyone then settles each slot.
  defp refund_steps(assigns) do
    held =
      for placement <- assigns.placements,
          leases = Map.get(assigns.leases, placement.placement_id, []),
          Enum.any?(leases, &(&1.campaign_id == assigns.campaign.campaign_id)),
          do: %{placement: placement, slots: Enum.map(leases, & &1.slot)}

    assigns = assign(assigns, held: held)

    ~H"""
    <div class="pb-oa-steps" id={"pb-oa-refund-#{@campaign.id}"}>
      <p :if={@held == []} class="patchbay-muted">Pulled. No live lease holds its money.</p>
      <div :if={@held != []}>
        <p>
          Pulled, and no longer shown. Its paid leases are refunded only from Base, by the publisher's wallet:
        </p>
        <ol class="pb-oa-step-list">
          <li :for={%{placement: placement, slots: slots} <- @held}>
            End placement {placement.placement_id} on {placement.source_origin} (terminatePlacement), then settle {slot_words(
              slots
            )} (settleTerminated); anyone may
            settle. Every lease in that placement is refunded for the time it had left, not only
            this campaign's.
          </li>
        </ol>
      </div>
    </div>
    """
  end

  attr :rules, :list, required: true

  defp advertisers(assigns) do
    ~H"""
    <section
      id="pb-oa-advertisers"
      class="pb-sheet-section"
      aria-labelledby="pb-oa-advertisers-title"
    >
      <h2 id="pb-oa-advertisers-title">Advertisers</h2>
      <p class="patchbay-muted">
        Only wallets Patchbay accepts are shown. A blocked wallet stays blocked, even if accepted or in a pool.
      </p>

      <form id="pb-oa-rule" phx-submit="set_rule" class="pb-offmod-actions">
        <Primitives.field id="pb-oa-rule-wallet" label="Wallet">
          <input
            id="pb-oa-rule-wallet"
            type="text"
            name="wallet"
            placeholder="0x"
            required
            autocomplete="off"
            spellcheck="false"
          />
        </Primitives.field>
        <Primitives.button type="submit" name="verdict" value="accepted" variant="primary">
          Accept
        </Primitives.button>
        <Primitives.button type="submit" name="verdict" value="blocked" variant="secondary">
          Block
        </Primitives.button>
      </form>

      <ul :if={@rules != []} class="pb-oa-list" id="pb-oa-rules">
        <li :for={rule <- @rules} id={"pb-oa-rule-#{rule.id}"} class="pb-oa-row pb-oa-line">
          <Primitives.address id={"pb-oa-rule-#{rule.id}-wallet"} address={rule.wallet} />
          <span class={["patchbay-pill", verdict_tone(rule.verdict)]}>
            {verdict_label(rule.verdict)}
          </span>
          <button
            type="button"
            class="pb-oa-remove"
            phx-click="remove_rule"
            phx-value-id={rule.id}
            aria-label={"Remove #{verdict_label(rule.verdict)} for #{rule.wallet}"}
          >
            Remove
          </button>
        </li>
      </ul>
    </section>
    """
  end

  attr :pools, :list, required: true

  defp pools(assigns) do
    ~H"""
    <section id="pb-oa-pools" class="pb-sheet-section" aria-labelledby="pb-oa-pools-title">
      <h2 id="pb-oa-pools-title">Pools</h2>
      <p class="patchbay-muted">
        A pool keeps campaigns about its tags, from its members. With no tags it keeps any campaign; with no members, any accepted wallet. A placement with no pools chosen shows from General: every accepted campaign.
      </p>

      <form id="pb-oa-new-pool" phx-submit="create_pool" class="pb-offmod-actions">
        <Primitives.field id="pb-oa-pool-name" label="Name">
          <input id="pb-oa-pool-name" type="text" name="name" maxlength="40" required />
        </Primitives.field>
        <Primitives.field id="pb-oa-pool-tags" label="Tags">
          <input
            id="pb-oa-pool-tags"
            type="text"
            name="tags"
            placeholder="payments, auth"
            autocomplete="off"
          />
        </Primitives.field>
        <Primitives.button type="submit" variant="secondary">Add pool</Primitives.button>
      </form>

      <ul :if={@pools != []} class="pb-oa-list" id="pb-oa-pool-list">
        <li :for={pool <- @pools} id={"pb-oa-pool-#{pool.id}"} class="pb-oa-row">
          <div class="pb-oa-row-head">
            <strong class="pb-oa-name">{pool.name}</strong>
            <span class="pb-oa-meta">
              {if pool.tags == [], do: "Any topic", else: Enum.join(pool.tags, ", ")}
            </span>
            <button
              type="button"
              class="pb-oa-remove"
              phx-click="delete_pool"
              phx-value-id={pool.id}
              data-confirm={"Remove the pool #{pool.name}? Placements stop showing from it."}
              data-confirm-action="Remove"
            >
              Remove
            </button>
          </div>
          <ul class="pb-oa-members">
            <li :if={pool.members == []} class="patchbay-muted">Any accepted wallet</li>
            <li :for={member <- pool.members} id={"pb-oa-member-#{member.id}"} class="pb-oa-line">
              <Primitives.address
                id={"pb-oa-member-#{member.id}-wallet"}
                address={member.wallet}
                variant="compact"
              />
              <button
                type="button"
                class="pb-oa-remove"
                phx-click="remove_member"
                phx-value-id={member.id}
                aria-label={"Remove #{member.wallet} from #{pool.name}"}
              >
                Remove
              </button>
            </li>
          </ul>
          <form id={"pb-oa-add-member-#{pool.id}"} phx-submit="add_member" class="pb-offmod-actions">
            <input type="hidden" name="pool_id" value={pool.id} />
            <Primitives.field id={"pb-oa-member-wallet-#{pool.id}"} label="Member">
              <input
                id={"pb-oa-member-wallet-#{pool.id}"}
                type="text"
                name="wallet"
                placeholder="0x"
                required
                autocomplete="off"
                spellcheck="false"
              />
            </Primitives.field>
            <Primitives.button type="submit" variant="secondary">Add</Primitives.button>
          </form>
        </li>
      </ul>
    </section>
    """
  end

  attr :admin, :map, required: true

  defp placements(assigns) do
    ~H"""
    <section
      id="pb-oa-placements"
      class="pb-sheet-section"
      aria-labelledby="pb-oa-placements-title"
    >
      <h2 id="pb-oa-placements-title">Placements</h2>
      <p :if={@admin.cursor && !@admin.cursor.fresh?} class="patchbay-muted">
        The record may be behind Base by a few minutes.
      </p>

      <Primitives.empty_state
        :if={@admin.placements == []}
        id="pb-oa-no-placements"
        title="No placements"
      >
        Placements appear here once the publisher's wallet creates them on Base.
      </Primitives.empty_state>

      <ul :if={@admin.placements != []} class="pb-oa-list">
        <li
          :for={placement <- @admin.placements}
          id={"pb-oa-placement-#{placement.placement_id}"}
          class="pb-oa-row"
        >
          <div class="pb-oa-row-head">
            <strong class="pb-oa-name">
              {placement.source_origin || "Unlisted site"}
            </strong>
            <span class="pb-oa-meta">
              Placement {placement.placement_id} · {placement.capacity} slots · {div(
                placement.duration_seconds,
                3600
              )}h leases
            </span>
          </div>

          <div class="pb-oa-pools-chosen">
            <span class="pb-oa-label">Shows from</span>
            <span :if={Map.get(@admin.chosen, placement.placement_id, []) == []} class="pb-oa-chip">
              General
            </span>
            <span
              :for={choice <- Map.get(@admin.chosen, placement.placement_id, [])}
              id={"pb-oa-choice-#{choice.id}"}
              class="pb-oa-chip"
            >
              {choice.pool.name}
              <button
                type="button"
                phx-click="drop_pool"
                phx-value-id={choice.id}
                aria-label={"Stop showing from #{choice.pool.name}"}
              >
                <Regent.Icons.icon name="x" />
              </button>
            </span>
            <form
              :if={@admin.pools != []}
              id={"pb-oa-choose-#{placement.placement_id}"}
              phx-submit="choose_pool"
              class="pb-oa-choose"
            >
              <input type="hidden" name="placement_id" value={placement.placement_id} />
              <label class="visually-hidden" for={"pb-oa-pool-for-#{placement.placement_id}"}>
                Pool
              </label>
              <select id={"pb-oa-pool-for-#{placement.placement_id}"} name="pool_id">
                <option :for={pool <- @admin.pools} value={pool.id}>{pool.name}</option>
              </select>
              <Primitives.button type="submit" variant="secondary">Add</Primitives.button>
            </form>
          </div>

          <table class="pb-oa-leases">
            <thead>
              <tr>
                <th scope="col">Slot</th>
                <th scope="col">Campaign</th>
                <th scope="col">Ends</th>
                <th scope="col" class="pb-oa-num">Shown</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{slot, lease} <- slots(placement, @admin.leases)}>
                <td>{slot + 1}</td>
                <td :if={!lease} colspan="3" class="patchbay-muted">Open</td>
                <td :if={lease}>{Map.get(@admin.titles, lease.campaign_id, "Unknown campaign")}</td>
                <td :if={lease}>{moment(lease.ends_at)}</td>
                <td :if={lease} class="pb-oa-num">{lease.delivery_count}</td>
              </tr>
            </tbody>
          </table>
        </li>
      </ul>
    </section>
    """
  end

  # Each slot of a placement with the lease it shows now, if any.
  defp slots(placement, leases) do
    held = Map.new(Map.get(leases, placement.placement_id, []), &{&1.slot, &1})
    for slot <- 0..(placement.capacity - 1), do: {slot, held[slot]}
  end

  defp targeting(campaign) do
    [
      campaign.tags != [] && "Tags " <> Enum.join(campaign.tags, ", "),
      campaign.kinds != [] &&
        "Threads " <>
          Enum.map_join(campaign.kinds, ", ", &Patchbay.Forum.Types.ThreadKind.label/1),
      :paired in campaign.requires && "Paired agents",
      campaign.excluded_wallets != [] &&
        "#{length(campaign.excluded_wallets)} wallets left out",
      campaign.daily_limit && "#{campaign.daily_limit} a day each"
    ]
    |> Enum.filter(& &1)
  end

  # Slots as the page counts them, and as Base numbers them for the step.
  defp slot_words([slot]), do: "slot #{slot + 1}, number #{slot} on Base"

  defp slot_words(slots) do
    slots = Enum.sort(slots)

    "slots #{Enum.map_join(slots, ", ", &(&1 + 1))}, numbers #{Enum.join(slots, ", ")} on Base"
  end

  defp review_label(:waiting), do: "Waiting"
  defp review_label(:approved), do: "Approved"
  defp review_label(:pulled), do: "Pulled"

  defp review_tone(:waiting), do: nil
  defp review_tone(:approved), do: "is-good"
  defp review_tone(:pulled), do: "is-bad"

  defp verdict_label(:accepted), do: "Accepted"
  defp verdict_label(:blocked), do: "Blocked"

  defp verdict_tone(:accepted), do: "is-good"
  defp verdict_tone(:blocked), do: "is-bad"
end
