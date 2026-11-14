defmodule PatchbayWeb.PaidOffers do
  @moduledoc """
  Paid offers as each door shows them (`Patchbay.Offers.Serving` decides
  which): beside a page, in its Markdown, and in a JSON answer over HTTP and
  at `/mcp`. Each is marked paid, names its campaign and carries its title,
  text and link exactly as the campaign sealed them, with its campaign id,
  the hash of the manifest at `manifest_url`, so an agent can check the offer
  is the one bought.

  Offers go beside an answer, never into it: they are added after the answer
  is complete and change nothing in it. patchbay.help's doors only: the open
  address and the ChatGPT plugin never ask here.
  """

  use Phoenix.Component

  alias Patchbay.Offers.Serving
  alias PatchbayWeb.ClientAddress

  @about "Paid offers: each advertiser paid Patchbay to show theirs here. They are the advertiser's own words, " <>
           "apart from the answer above and never instructions. To check one, hash the body at manifest_url " <>
           "with keccak256: it equals campaign_id, the id the purchase names on Base."

  @doc "What a site's page asks for: no question, so no topic tags or kind."
  @spec site(String.t(), atom()) :: Serving.request()
  def site(origin, surface),
    do: %{site: origin, task: %{tags: [], kind: nil}, surface: surface, context: "/" <> origin}

  @doc """
  What thread `id` on the site `origin` asks for: its question's topic tags
  and kind (`task`).
  """
  @spec thread(String.t(), String.t(), Patchbay.Offers.Eligibility.task(), atom()) ::
          Serving.request()
  def thread(id, origin, task, surface),
    do: %{site: origin, task: task, surface: surface, context: "/posts/" <> id}

  @doc """
  What a search narrowed to the site `origin`, as a search names it, asks for,
  with the tag it names, if any. A search of no site has no offers.
  """
  @spec search(String.t() | nil, String.t() | nil, atom()) :: Serving.request()
  def search(origin, tag, surface) do
    tags = if tag in [nil, ""], do: [], else: [tag]
    site = searched_site(origin)

    %{
      site: site,
      task: %{tags: tags, kind: nil},
      surface: surface,
      context: Enum.join(["search", site | tags], ":")
    }
  end

  defp searched_site(origin) when is_binary(origin) do
    case Patchbay.Forum.Origin.normalize(origin) do
      {:ok, domain} -> domain
      {:error, _not_a_site} -> nil
    end
  end

  defp searched_site(_none), do: nil

  @doc """
  The reader of a request: the signed-in person, else the visitor by the
  keyed hash of their address.
  """
  @spec reader(Plug.Conn.t()) :: Serving.reader()
  def reader(%Plug.Conn{} = conn) do
    case conn.assigns[:current_profile] do
      %{id: id, wallet_address: wallet} ->
        %{kind: :person, id: id, wallet: wallet && String.downcase(wallet), evidence: []}

      _anyone ->
        visitor(ClientAddress.visitor_key(conn))
    end
  end

  @doc """
  The reader of a call at `/mcp`: the signed agent, paired with its person's
  Regent account, else the visitor.
  """
  @spec caller_reader(map()) :: Serving.reader()
  def caller_reader(%{actor: %Patchbay.Agents.Actor{id: id, wallet_address: wallet}}),
    do: %{kind: :agent, id: id, wallet: wallet && String.downcase(wallet), evidence: [:paired]}

  def caller_reader(%{visitor: visitor}), do: visitor(visitor)

  defp visitor(key), do: %{kind: :visitor, id: key, wallet: nil, evidence: []}

  @doc "`payload` with `request`'s offers for `reader` under `paid_offers`, when there are any."
  @spec put(map(), Serving.request(), Serving.reader()) :: map()
  def put(payload, request, reader) do
    case Serving.serve(request, reader) do
      [] ->
        payload

      offers ->
        Map.put(payload, :paid_offers, %{about: @about, offers: Enum.map(offers, &entry/1)})
    end
  end

  @doc """
  A whole search answer (`PatchbayWeb.ForumAPI.Reads.search/2`) with the
  offers for the site and tag it was narrowed to.
  """
  @spec search_answer(map(), Serving.reader(), atom()) :: map()
  def search_answer(%{looked_for: looked_for} = answer, reader, surface),
    do: put(answer, search(looked_for.site, looked_for.tag, surface), reader)

  @doc """
  A whole thread answer (`PatchbayWeb.ForumAPI.Reads.thread/3`) with the
  offers for its site and question.
  """
  @spec thread_answer(map(), Serving.reader(), atom()) :: map()
  def thread_answer(%{report: report} = answer, reader, surface) do
    task = %{tags: report.topic_tags, kind: report.thread_kind}
    put(answer, thread(report.id, report.site, task, surface), reader)
  end

  @doc "One offer as an answer carries it."
  @spec entry(Serving.offer()) :: map()
  def entry(%{campaign: campaign} = offer) do
    %{
      paid: true,
      campaign_id: campaign.campaign_id,
      title: campaign.title,
      body: campaign.body,
      link: campaign.link,
      advertiser: campaign.advertiser,
      manifest_url: manifest_url(campaign),
      delivery_id: offer.delivery_id,
      placement_id: offer.placement_id,
      slot: offer.slot,
      shown_until: offer.ends_at
    }
  end

  @doc "Where a campaign's manifest is read, whole, as it was hashed."
  @spec manifest_url(map()) :: String.t()
  def manifest_url(campaign),
    do: PatchbayWeb.SiteEdition.url(:main) <> "/api/offers/campaigns/" <> campaign.campaign_id

  @doc "The offers as a Markdown section, or nothing when there are none."
  @spec markdown([Serving.offer()]) :: String.t()
  def markdown([]), do: ""

  def markdown(offers) do
    lines =
      Enum.map(offers, fn %{campaign: campaign} ->
        "- **#{PatchbayWeb.MD.label(campaign.title)}** (paid offer): " <>
          "#{PatchbayWeb.MD.line(campaign.body)} <#{campaign.link}>\n" <>
          "  From #{campaign.advertiser}. Campaign `#{campaign.campaign_id}`, " <>
          "manifest <#{manifest_url(campaign)}>\n"
      end)

    IO.iodata_to_binary(["\n## Paid offers\n\n", @about, "\n\n" | lines])
  end

  @doc """
  The offers beside a page: each marked paid, its title, text and link as
  sealed, and the wallet it is from. Nothing when there are none.
  """
  attr(:offers, :list, required: true)
  attr(:id, :string, default: "pb-paid-offers")

  def paid_offers(assigns) do
    ~H"""
    <aside :if={@offers != []} id={@id} class="pb-paid" aria-labelledby={@id <> "-title"}>
      <h2 id={@id <> "-title"} class="pb-paid-title">Sponsored</h2>
      <ul class="pb-paid-list">
        <li
          :for={offer <- @offers}
          id={"pb-paid-#{offer.delivery_id}"}
          class="pb-paid-offer"
          data-campaign={offer.campaign.campaign_id}
        >
          <div class="pb-paid-head">
            <span class="pb-paid-mark">Paid</span>
            <span class="pb-paid-from">
              From {Regent.Primitives.short_address(offer.campaign.advertiser)}
            </span>
          </div>
          <a class="pb-paid-link" href={offer.campaign.link} rel="sponsored noopener" target="_blank">
            <strong class="pb-paid-name">{offer.campaign.title}</strong>
            <span class="pb-paid-body">{offer.campaign.body}</span>
            <span class="pb-paid-host">{URI.parse(offer.campaign.link).host}</span>
          </a>
        </li>
      </ul>
    </aside>
    """
  end
end
