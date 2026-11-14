defmodule Patchbay.Offers.Serving do
  @moduledoc """
  The paid offers that go with one page or answer, for one reader. Every door
  that shows offers asks here and nowhere else: a site's page and its
  Markdown, a thread, a search, the incidents, a post's answer, over HTTP and
  at `/mcp`.

  What the page is about names the sources tried, in order
  (`Patchbay.Offers.Source.order/1`): its site's, or CVE incidents', then
  General's. The first source with an offer for this reader is shown, and the
  rest are not read further. In a source, offers come in this order, and stop
  there:

    1. a reservation: each open placement for the source, oldest first, and
       in it each slot in order, shows the offer its live lease paid for,
       when the campaign is eligible there and for this reader
       (`Patchbay.Offers.Eligibility`) and the reader has not reached its
       daily limit; so at most each placement's capacity;
    2. a per-delivery offer, paid each time it is shown, would follow the
       reservations here, through the same request and reader; the market
       sells none yet, and a slot shown as reserved is never charged again;
    3. otherwise nothing.

  However many placements there are, a page reads the same handful of
  queries: its sources' placements, their live leases, their campaigns and
  Patchbay's terms for them, each once.

  Each offer shown is written once as a `Patchbay.Offers.Delivery`, so the
  same page read again by the same reader on the same day is the same
  delivery, and a daily limit counts each page once. Offers are added beside
  an answer, never in it: nothing here reads, orders or hides what the
  answer says.

  Patchbay's side is read as the system. While no market is set, nothing is
  read and nothing is shown.
  """

  alias Patchbay.Offers
  alias Patchbay.Offers.Eligibility
  alias Patchbay.Offers.Source

  @system %{role: :system}

  @typedoc """
  What the offers go with: what the page is about (`Source.about/0`), the
  question's tags and kind of thread (`Eligibility.task/0`), the door
  (`:page`, `:markdown`, `:json` or `:mcp`), and `context`, the page or
  answer itself, which makes a delivery the same one when it is read again.
  """
  @type request :: %{
          about: Source.about(),
          task: Eligibility.task(),
          surface: :page | :markdown | :json | :mcp,
          context: String.t()
        }

  @typedoc """
  Who reads it: a signed agent, a signed-in person or a visitor, by the id
  deliveries keep, with the wallet and proof `Eligibility.qualifies/3` reads.
  """
  @type reader :: %{
          kind: :agent | :person | :visitor,
          id: String.t(),
          wallet: String.t() | nil,
          evidence: [atom()]
        }

  @type offer :: %{
          delivery_id: String.t(),
          campaign: map(),
          placement_id: pos_integer(),
          slot: non_neg_integer(),
          ends_at: DateTime.t()
        }

  @doc "The offers for `request` read by `reader`, in the order to show them."
  @spec serve(request(), reader()) :: [offer()]
  def serve(request, reader) do
    if Offers.enabled?(), do: serve_enabled(request, reader), else: []
  end

  defp serve_enabled(request, reader) do
    %{chain_id: chain_id} = Offers.chain()
    market = Offers.market()
    sources = Source.order(request.about)
    placements = Offers.source_placements!(chain_id, market, sources, actor: @system)
    capacity = Map.new(placements, &{&1.placement_id, &1.capacity})

    # Each slot's newest live lease, placement by placement, oldest first.
    leases =
      chain_id
      |> Offers.placement_leases!(market, Map.keys(capacity), actor: @system)
      |> Enum.uniq_by(&{&1.placement_id, &1.slot})
      |> Enum.filter(&(&1.slot < capacity[&1.placement_id]))

    offers =
      for {lease, campaign, placement} <- Eligibility.runnable(placements, leases),
          Eligibility.qualifies(campaign, request.task, reader) == :ok,
          do: {placement.source_origin, {lease, campaign}}

    Enum.find_value(sources, [], &shown(&1, offers, request, reader))
  end

  # The offers from `source` this reader may see on this page, each delivered;
  # nil when there are none, so the next source is tried.
  defp shown(source, offers, request, reader) do
    case within_limits(for({^source, offer} <- offers, do: offer), request, reader) do
      [] -> nil
      kept -> Enum.map(kept, &deliver(&1, request, reader))
    end
  end

  # A campaign with a daily limit is shown to one reader on at most that many
  # pages a day; a page it was already shown with today shows it again
  # without counting. Two pages read at the same moment may each take the last
  # place.
  defp within_limits(shown, request, reader) do
    limited = for {_lease, %{daily_limit: limit} = campaign} <- shown, limit, do: campaign
    today = today(limited, reader)

    {kept, _counts} =
      Enum.flat_map_reduce(shown, counts(today), fn {lease, campaign} = offer, counts ->
        seen = Map.get(counts, campaign.campaign_id, MapSet.new())
        page = {lease.id, request.context}

        cond do
          campaign.daily_limit == nil or page in seen -> {[offer], counts}
          MapSet.size(seen) < campaign.daily_limit -> {[offer], add(counts, campaign, page)}
          true -> {[], counts}
        end
      end)

    kept
  end

  defp today([], _reader), do: []

  defp today(campaigns, reader) do
    Offers.deliveries_today!(
      reader.kind,
      reader.id,
      Enum.map(campaigns, & &1.campaign_id),
      actor: @system
    )
  end

  defp counts(deliveries) do
    Enum.reduce(deliveries, %{}, fn delivery, counts ->
      add(counts, delivery, {delivery.lease_id, delivery.context})
    end)
  end

  defp add(counts, %{campaign_id: campaign_id}, page),
    do: Map.update(counts, campaign_id, MapSet.new([page]), &MapSet.put(&1, page))

  defp deliver({lease, campaign}, request, reader) do
    delivery =
      Offers.record_delivery!(
        %{
          lease_id: lease.id,
          campaign_id: campaign.campaign_id,
          surface: request.surface,
          viewer_kind: reader.kind,
          viewer: reader.id,
          context: request.context
        },
        actor: @system
      )

    %{
      delivery_id: delivery.id,
      campaign: campaign,
      placement_id: lease.placement_id,
      slot: lease.slot,
      ends_at: lease.ends_at
    }
  end
end
