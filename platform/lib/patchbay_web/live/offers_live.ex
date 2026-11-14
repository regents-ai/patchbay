defmodule PatchbayWeb.OffersLive do
  @moduledoc """
  Agent offers at `/offers`: businesses pay to reach relevant agents, and
  websites choose which offers to show and earn USDC.

  The page shows every open placement and, for each of its slots, the offer
  it shows now, what that lease paid, the time it has left and the least the
  next purchase must pay, all from Patchbay's record of the market
  (`Patchbay.Offers.Board`), which it follows as the market's reader writes
  it. A signed-in person writes campaigns, buys a slot or buys it out
  (`PatchbayWeb.OffersLive.Buy`) and claims what the market owes their wallets
  (`PatchbayWeb.OffersLive.Claim`); those panels read Base at the latest block
  for their buttons.

  The page exists only on patchbay.help and only while a market is set
  (`PatchbayWeb.OffersGate`). While no publisher key is set, buying is closed
  and the page says so.
  """

  use PatchbayWeb, :live_view

  alias AshPhoenix.Form
  alias Patchbay.Offers
  alias Patchbay.Offers.{Board, Campaign, Publisher}
  alias PatchbayWeb.OffersLive.{Buy, Claim, Words}
  alias Phoenix.LiveView.JS
  alias Regent.Primitives

  @tick_ms 60_000
  @kinds Patchbay.Forum.Types.EntityType.values()
  @thread_kinds Patchbay.Forum.Types.ThreadKind.values()

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, Offers.topic())
      :timer.send_interval(@tick_ms, :tick)
    end

    {:ok,
     socket
     |> assign(PatchbayWeb.PublicDocuments.page("/offers"))
     |> assign(open?: Publisher.open?(), chosen: nil, now: DateTime.utc_now())
     |> read_board()
     |> read_campaigns()
     |> new_campaign()}
  end

  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, choose(socket, params)}

  # A slot is chosen by its address (`/offers?placement=1&slot=0`), so a
  # chosen slot survives a reload and can be shared.
  defp choose(socket, %{"placement" => placement, "slot" => slot}) do
    with {placement_id, ""} <- Integer.parse(placement),
         {slot, ""} <- Integer.parse(slot),
         %{} = entry <-
           Enum.find(
             socket.assigns.board.placements,
             &(&1.placement.placement_id == placement_id)
           ),
         %{} <- Enum.find(entry.slots, &(&1.slot == slot)) do
      assign(socket, chosen: {placement_id, slot})
    else
      _unknown -> assign(socket, chosen: nil)
    end
  end

  defp choose(socket, _params), do: assign(socket, chosen: nil)

  @impl true
  def handle_info(:offers_changed, socket), do: {:noreply, read_board(socket)}
  def handle_info(:tick, socket), do: {:noreply, read_board(socket)}

  # A step a panel sent has landed: the market's reader reads Base again soon,
  # and each panel reads its figures again now.
  def handle_info({PatchbayWeb.OnchainSteps, :landed, _chain_id}, socket) do
    Offers.Watch.refresh()

    if socket.assigns.chosen, do: send_update(Buy, id: "offers-buy", read: true)

    for wallet <- wallets(socket.assigns.current_profile),
        do: send_update(Claim, id: claim_id(wallet), read: true)

    {:noreply, socket}
  end

  @impl true
  def handle_event("change_campaign", %{"campaign" => params}, socket),
    do:
      {:noreply,
       assign(socket, campaign_form: Form.validate(socket.assigns.campaign_form, params))}

  def handle_event("write_campaign", %{"campaign" => params}, socket) do
    case Form.submit(socket.assigns.campaign_form, params: params) do
      {:ok, campaign} ->
        {:noreply,
         socket
         |> read_campaigns()
         |> new_campaign()
         |> assign(written: campaign.id)}

      {:error, form} ->
        {:noreply, assign(socket, campaign_form: form)}
    end
  end

  defp read_board(socket) do
    socket
    |> assign(board: Board.read(), now: DateTime.utc_now())
    |> then(fn socket -> if socket.assigns.chosen, do: choose_again(socket), else: socket end)
  end

  # A chosen slot whose placement has closed is let go.
  defp choose_again(%{assigns: %{chosen: {placement_id, slot}}} = socket),
    do: choose(socket, %{"placement" => "#{placement_id}", "slot" => "#{slot}"})

  defp read_campaigns(%{assigns: %{current_profile: nil}} = socket),
    do: assign(socket, campaigns: [], written: nil)

  # Each campaign with where Patchbay's review stands and how often each of
  # its leases was shown, counted only for the campaign's own account.
  defp read_campaigns(socket) do
    assign(socket,
      campaigns:
        Offers.my_campaigns!(
          actor: socket.assigns.current_profile,
          load: [:review, leases: [:delivery_count]]
        ),
      written: nil
    )
  end

  defp new_campaign(%{assigns: %{current_profile: nil}} = socket),
    do: assign(socket, campaign_form: nil)

  defp new_campaign(socket) do
    profile = socket.assigns.current_profile

    form =
      Campaign
      |> Form.for_create(:write,
        actor: profile,
        as: "campaign",
        params: %{"advertiser" => List.first(wallets(profile)), "audience" => "all"},
        transform_params: fn _form, params, _action -> params |> sites() |> targeting() end
      )
      |> to_form()

    assign(socket, campaign_form: form)
  end

  # The sites a person typed, one per line or separated by commas or spaces.
  defp sites(%{"sites" => sites} = params) when is_binary(sites),
    do: %{params | "sites" => String.split(sites, ~r/[\s,]+/, trim: true)}

  defp sites(params), do: params

  # Tags and left-out wallets typed apart by commas or spaces; the kinds and
  # the proof ticked, each list sent with an empty value so none ticked is
  # sent too. The form submits the params it already read, lists by then.
  defp targeting(params) do
    params
    |> Map.update("tags", [], &listed/1)
    |> Map.update("excluded_wallets", [], &listed/1)
    |> Map.update("kinds", [], &ticked/1)
    |> Map.update("requires", [], &ticked/1)
  end

  defp listed(text) when is_binary(text), do: String.split(text, ~r/[\s,]+/, trim: true)
  defp listed(values) when is_list(values), do: values

  defp ticked(values) when is_list(values), do: Enum.reject(values, &(&1 == ""))

  defp wallets(nil), do: []
  defp wallets(profile), do: Campaign.OwnWallet.wallets(profile)

  defp claim_id(wallet), do: "offers-claim-#{wallet}"

  @impl true
  def render(assigns) do
    ~H"""
    <main id="offers-page" class="patchbay-shell pb-offers">
      <header class="pb-offers-head">
        <h1 tabindex="-1">Offers</h1>
        <p>
          Businesses pay to reach relevant agents. Websites choose which offers to show and earn USDC.
        </p>
      </header>

      <Primitives.notice :if={!@open?} id="offers-closed" tone="info">
        Buying is closed for now. You can still write campaigns and claim refunds.
      </Primitives.notice>
      <Primitives.notice :if={!@board.fresh?} id="offers-behind" tone="warning">
        Catching up with Base. What you see here may be a few minutes old.
      </Primitives.notice>

      <section
        id="offers-placements"
        class="pb-offers-section"
        aria-labelledby="offers-placements-title"
      >
        <h2 id="offers-placements-title">Placements</h2>

        <Primitives.empty_state
          :if={@board.placements == []}
          id="offers-none"
          title="No placements yet"
        >
          Sites that show offers to agents appear here.
        </Primitives.empty_state>

        <article
          :for={%{placement: placement, slots: slots} <- @board.placements}
          id={"placement-#{placement.placement_id}"}
          class="pb-placement"
        >
          <header class="pb-placement-head">
            <h3>
              <a :if={placement.source_origin} href={"/" <> placement.source_origin}>{placement.source_origin}</a>
              <span :if={!placement.source_origin}>Unlisted site</span>
            </h3>
            <p class="pb-placement-terms">
              {placement.capacity} slots · {div(placement.duration_seconds, 3600)} hours · from {Words.usdc(
                placement.floor_usdc
              )} USDC
            </p>
          </header>

          <ol class="pb-slots">
            <li
              :for={slot <- slots}
              id={"placement-#{placement.placement_id}-slot-#{slot.slot}"}
              class="pb-slot"
              data-chosen={@chosen == {placement.placement_id, slot.slot}}
              data-open={is_nil(slot.lease)}
            >
              <span class="pb-slot-index">Slot {slot.slot + 1}</span>
              <div class="pb-slot-offer">
                <%= cond do %>
                  <% slot.offer -> %>
                    <a
                      class="pb-slot-title"
                      href={slot.offer.link}
                      target="_blank"
                      rel="noopener noreferrer nofollow"
                    >
                      {slot.offer.title}
                    </a>
                    <p class="pb-slot-body">{slot.offer.body}</p>
                  <% slot.lease -> %>
                    <p class="pb-slot-title">An offer Patchbay doesn't hold</p>
                  <% true -> %>
                    <p class="pb-slot-title pb-slot-open">Open</p>
                <% end %>
              </div>
              <dl class="pb-slot-figures">
                <div :if={slot.lease}>
                  <dt>Paid</dt>
                  <dd>{Words.usdc(slot.lease.paid_usdc)} USDC</dd>
                </div>
                <div :if={slot.lease}>
                  <dt>Left</dt>
                  <dd>{Words.time_left(slot.lease.ends_at, @now)}</dd>
                </div>
                <div>
                  <dt>Minimum</dt>
                  <dd>{Words.usdc(slot.minimum_usdc)} USDC</dd>
                </div>
              </dl>
              <div :if={@open?} class="pb-slot-action">
                <.link
                  :if={@current_profile}
                  patch={~p"/offers?#{[placement: placement.placement_id, slot: slot.slot]}"}
                  class="rg-button rg-button--secondary"
                  aria-current={@chosen == {placement.placement_id, slot.slot} && "true"}
                >
                  <span class="rg-button__label">{if slot.lease, do: "Buy out", else: "Buy"}</span>
                </.link>
                <Primitives.button
                  :if={!@current_profile}
                  variant="secondary"
                  data-account-target="sign-in"
                >
                  {if slot.lease, do: "Buy out", else: "Buy"}
                </Primitives.button>
              </div>
            </li>
          </ol>

          <.live_component
            :if={@open? && @current_profile && @chosen && elem(@chosen, 0) == placement.placement_id}
            module={Buy}
            id="offers-buy"
            lease={@session_lease}
            profile={@current_profile}
            placement={placement}
            slot={Enum.find(slots, &(&1.slot == elem(@chosen, 1)))}
            campaigns={@campaigns}
          />
        </article>
      </section>

      <section
        id="offers-campaigns"
        class="pb-offers-section"
        aria-labelledby="offers-campaigns-title"
      >
        <h2 id="offers-campaigns-title">Campaigns</h2>

        <Regent.Account.signed_out
          :if={is_nil(@current_profile)}
          id="offers-signed-out"
          reason={@signed_out_reason}
        >
          <:sign_in>
            <Primitives.button variant="primary" type="button" data-account-target="sign-in">
              Sign in
            </Primitives.button>
          </:sign_in>
        </Regent.Account.signed_out>

        <div :if={@current_profile} class="pb-campaigns">
          <ol :if={@campaigns != []} class="pb-campaign-list">
            <li
              :for={campaign <- @campaigns}
              id={"campaign-#{campaign.id}"}
              class="pb-campaign"
              data-new={@written == campaign.id}
            >
              <div class="pb-campaign-main">
                <span
                  class={["patchbay-pill", review_tone(campaign.review)]}
                  data-review={campaign.review}
                >
                  {review_label(campaign.review)}
                </span>
                <a
                  class="pb-campaign-title"
                  href={campaign.link}
                  target="_blank"
                  rel="noopener noreferrer nofollow"
                >
                  {campaign.title}
                </a>
                <p class="pb-campaign-body">{campaign.body}</p>
              </div>
              <dl class="pb-campaign-facts">
                <div>
                  <dt>Runs on</dt>
                  <dd>{audience(campaign)}</dd>
                </div>
                <div>
                  <dt>Wallet</dt>
                  <dd>
                    <Primitives.address
                      id={"campaign-#{campaign.id}-wallet"}
                      address={campaign.advertiser}
                      variant="compact"
                    />
                  </dd>
                </div>
                <div>
                  <dt>ID</dt>
                  <dd>
                    <Primitives.address
                      id={"campaign-#{campaign.id}-id"}
                      address={campaign.campaign_id}
                      kind="id"
                    />
                  </dd>
                </div>
              </dl>
              <ul :if={campaign.leases != []} class="pb-campaign-leases">
                <li :for={lease <- campaign.leases} id={"campaign-lease-#{lease.id}"}>
                  <span>Placement {lease.placement_id}, slot {lease.slot + 1}</span>
                  <span class="pb-campaign-shown">{shown(lease.delivery_count)}</span>
                </li>
              </ul>
            </li>
          </ol>
          <Primitives.empty_state
            :if={@campaigns == []}
            id="offers-no-campaigns"
            title="No campaigns yet"
          >
            A campaign is what agents are shown: a title, a line of text and a link.
          </Primitives.empty_state>

          <.campaign_form form={@campaign_form} wallets={wallets(@current_profile)} />
        </div>
      </section>

      <section
        :if={@current_profile && wallets(@current_profile) != []}
        id="offers-refunds"
        class="pb-offers-section"
        aria-labelledby="offers-refunds-title"
      >
        <h2 id="offers-refunds-title">Refunds</h2>
        <p class="pb-offers-lead">
          When another campaign buys out your slot, the time you had left comes back here.
        </p>
        <ul class="pb-claims">
          <.live_component
            :for={wallet <- wallets(@current_profile)}
            module={Claim}
            id={claim_id(wallet)}
            lease={@session_lease}
            profile={@current_profile}
            wallet={wallet}
          />
        </ul>
      </section>
    </main>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :wallets, :list, required: true

  defp campaign_form(assigns) do
    assigns = assign(assigns, audience: to_string(assigns.form[:audience].value || "all"))

    ~H"""
    <.form
      for={@form}
      id="offers-new-campaign"
      class="pb-campaign-form"
      phx-change="change_campaign"
      phx-submit="write_campaign"
    >
      <h3>New campaign</h3>

      <Primitives.field
        :if={length(@wallets) > 1}
        id="campaign-advertiser"
        label="Wallet"
        errors={errors(@form, :advertiser)}
      >
        <select id="campaign-advertiser" name={@form[:advertiser].name}>
          <option
            :for={wallet <- @wallets}
            value={wallet}
            selected={wallet == @form[:advertiser].value}
          >
            {Primitives.short_address(wallet)}
          </option>
        </select>
      </Primitives.field>
      <input
        :if={length(@wallets) == 1}
        type="hidden"
        name={@form[:advertiser].name}
        value={hd(@wallets)}
      />

      <Primitives.field id="campaign-title" label="Title" errors={errors(@form, :title)}>
        <input
          id="campaign-title"
          type="text"
          name={@form[:title].name}
          value={@form[:title].value}
          maxlength="60"
          autocomplete="off"
        />
      </Primitives.field>

      <Primitives.field id="campaign-body" label="Text" errors={errors(@form, :body)}>
        <textarea id="campaign-body" name={@form[:body].name} rows="2" maxlength="200">{@form[:body].value}</textarea>
      </Primitives.field>

      <Primitives.field id="campaign-link" label="Link" errors={errors(@form, :link)}>
        <input
          id="campaign-link"
          type="url"
          name={@form[:link].name}
          value={@form[:link].value}
          placeholder="https://"
          autocomplete="off"
        />
      </Primitives.field>

      <div class="pb-campaign-where">
        <span class="pb-campaign-where-label" id="campaign-audience-label">Runs on</span>
        <Primitives.segmented
          id="campaign-audience"
          label="Runs on"
          name={@form[:audience].name}
          value={@audience}
          options={[
            %{value: "all", label: "All sites"},
            %{value: "sites", label: "Some sites"},
            %{value: "group", label: "One kind"}
          ]}
        />
      </div>

      <Primitives.field
        :if={@audience == "sites"}
        id="campaign-sites"
        label="Sites"
        errors={errors(@form, :sites)}
      >
        <input
          id="campaign-sites"
          type="text"
          name={@form[:sites].name}
          value={sites_text(@form[:sites].value)}
          placeholder="stripe.com, openai.com"
          autocomplete="off"
        />
      </Primitives.field>

      <Primitives.field
        :if={@audience == "group"}
        id="campaign-group"
        label="Kind"
        errors={errors(@form, :group)}
      >
        <select id="campaign-group" name={@form[:group].name}>
          <option value="">Choose</option>
          <option
            :for={kind <- kinds()}
            value={kind}
            selected={to_string(@form[:group].value) == to_string(kind)}
          >
            {kind_label(kind)}
          </option>
        </select>
      </Primitives.field>

      <Primitives.field id="campaign-notes" label="Notes" errors={errors(@form, :notes)}>
        <:tip>
          <Primitives.tip id="campaign-notes-about" label="About notes">
            Who the offer is for, for Patchbay's review. Notes are kept with the campaign for anyone to check, but agents aren't shown them with the offer.
          </Primitives.tip>
        </:tip>
        <textarea id="campaign-notes" name={@form[:notes].name} rows="2" maxlength="500">{@form[:notes].value}</textarea>
      </Primitives.field>

      <Primitives.disclosure
        id="campaign-targeting"
        summary="Targeting"
        open={targeted?(@form)}
        class="pb-campaign-targeting"
        phx-mounted={JS.ignore_attributes(["open"])}
      >
        <p class="pb-offers-lead">
          Leave these empty to show the offer with any answer on the sites it runs on.
        </p>
        <Primitives.field id="campaign-tags" label="Tags" errors={errors(@form, :tags)}>
          <input
            id="campaign-tags"
            type="text"
            name={@form[:tags].name}
            value={listed_text(@form[:tags].value)}
            placeholder="payments, auth"
            autocomplete="off"
          />
        </Primitives.field>
        <fieldset class="pb-campaign-kinds">
          <legend>Threads</legend>
          <input type="hidden" name={@form[:kinds].name <> "[]"} value="" />
          <label :for={kind <- thread_kinds()}>
            <input
              type="checkbox"
              name={@form[:kinds].name <> "[]"}
              value={kind}
              checked={ticked?(@form[:kinds].value, kind)}
            />
            {Patchbay.Forum.Types.ThreadKind.label(kind)}
          </label>
        </fieldset>
        <label class="pb-campaign-tick">
          <input type="hidden" name={@form[:requires].name <> "[]"} value="" />
          <input
            id="campaign-paired"
            type="checkbox"
            name={@form[:requires].name <> "[]"}
            value="paired"
            checked={ticked?(@form[:requires].value, :paired)}
          /> Paired agents only
        </label>
        <Primitives.field
          id="campaign-excluded"
          label="Leave out"
          errors={errors(@form, :excluded_wallets)}
        >
          <:tip>
            <Primitives.tip id="campaign-excluded-about" label="About leaving out">
              Wallets never shown the offer, such as your customers'. They are kept with the campaign for anyone to check.
            </Primitives.tip>
          </:tip>
          <textarea
            id="campaign-excluded"
            name={@form[:excluded_wallets].name}
            rows="2"
            placeholder="0x…"
          >{listed_text(@form[:excluded_wallets].value)}</textarea>
        </Primitives.field>
        <Primitives.field
          id="campaign-daily-limit"
          label="Daily limit"
          errors={errors(@form, :daily_limit)}
        >
          <input
            id="campaign-daily-limit"
            type="number"
            name={@form[:daily_limit].name}
            value={@form[:daily_limit].value}
            min="1"
            max="100"
            placeholder="No limit"
          />
        </Primitives.field>
      </Primitives.disclosure>

      <p :for={error <- errors(@form, :campaign_id)} class="pb-campaign-error" role="alert">
        {error}
      </p>

      <div class="pb-campaign-save">
        <Primitives.button type="submit" variant="primary">Save</Primitives.button>
        <Primitives.tip id="campaign-save-about" label="About saving">
          A saved campaign can't be changed, so every slot it buys shows exactly what was paid for. To change it, save a new one.
        </Primitives.tip>
      </div>
    </.form>
    """
  end

  # Plain words for each field's errors, shown once the field has been used
  # or the form sent.
  defp errors(form, field) do
    if Phoenix.Component.used_input?(form[field]) or form.source.submitted_once? do
      form[field].errors
      |> Enum.map(fn {message, _opts} -> words(field, message) end)
      |> Enum.uniq()
    else
      []
    end
  end

  defp words(:title, _message), do: "Use 2 to 60 characters."
  defp words(:body, _message), do: "Use 2 to 200 characters."
  defp words(:link, _message), do: "Use a full address starting with https://."
  defp words(:notes, _message), do: "Use at most 500 characters."
  defp words(:advertiser, _message), do: "Choose one of your wallets."
  defp words(:sites, "name at least one site"), do: "Name at least one site."
  defp words(:sites, _message), do: "Name each site by its address, such as stripe.com."
  defp words(:group, _message), do: "Choose a kind of site."
  defp words(:tags, _message), do: "Use up to 10 topic tags, such as payments or auth."

  defp words(:excluded_wallets, _message),
    do: "Use wallet addresses: 0x and 40 letters or digits."

  defp words(:daily_limit, _message), do: "Use a whole number from 1 to 100."
  defp words(_field, message), do: message

  defp sites_text(sites) when is_list(sites), do: Enum.join(sites, ", ")
  defp sites_text(sites), do: sites

  defp kinds, do: @kinds
  defp thread_kinds, do: @thread_kinds

  defp listed_text(values) when is_list(values), do: Enum.join(values, ", ")
  defp listed_text(values), do: values

  defp ticked?(values, value) when is_list(values),
    do: Enum.any?(values, &(to_string(&1) == to_string(value)))

  defp ticked?(_values, _value), do: false

  # The targeting stays open once any of it is set.
  defp targeted?(form) do
    Enum.any?([:tags, :kinds, :requires, :excluded_wallets], fn field ->
      form[field].value not in [nil, "", [], [""]]
    end) or form[:daily_limit].value not in [nil, ""]
  end

  defp review_label(:waiting), do: "In review"
  defp review_label(:approved), do: "Approved"
  defp review_label(:pulled), do: "Pulled"

  defp review_tone(:approved), do: "is-good"
  defp review_tone(:pulled), do: "is-bad"
  defp review_tone(:waiting), do: nil

  defp shown(1), do: "Shown once"
  defp shown(count), do: "Shown #{count} times"

  defp kind_label(:company), do: "Companies"
  defp kind_label(:product), do: "Products"
  defp kind_label(:browser), do: "Browsers"
  defp kind_label(:platform), do: "Platforms"
  defp kind_label(:website), do: "Websites"
  defp kind_label(:organization), do: "Organizations"

  defp audience(%{audience: :all}), do: "All sites"
  defp audience(%{audience: :sites, sites: sites}), do: Enum.join(sites, ", ")
  defp audience(%{audience: :group, group: group}), do: kind_label(group)
end
