defmodule Patchbay.Offers.Returns do
  @moduledoc """
  The public 72-hour figures of the Offers market, counted from the delivery
  records over the window `[as_of - 72 hours, as_of)`:

    * a site's eligible responses: new posts and replies about it that could
      carry Offers, whether or not any did;
    * a slot's returns: the responses that carried that slot's Offer;
    * a Global slot's opportunities: the eligible responses, on any site,
      where the site's slot of that number had nothing showing.

  The delivery records themselves stay private; only these counts are
  public, so each count reads past their policies deliberately.
  """

  require Ash.Query

  import Ash.Expr, only: [expr: 1]

  alias Patchbay.Offers.Delivery

  @window_hours 72

  @doc "The window ending at `as_of`, as `{since, as_of}`."
  @spec window(DateTime.t()) :: {DateTime.t(), DateTime.t()}
  def window(%DateTime{} = as_of), do: {DateTime.add(as_of, -@window_hours, :hour), as_of}

  @doc """
  Adds `:recent_responses` to a query of sites, read from each site's
  `aggregates`: its eligible responses in the window.
  """
  @spec count_site_responses(Ash.Query.t(), {DateTime.t(), DateTime.t()}) :: Ash.Query.t()
  def count_site_responses(query, {since, as_of}) do
    Ash.Query.aggregate(query, :recent_responses, :count, :offer_deliveries,
      query: [filter: expr(selected_at >= ^since and selected_at < ^as_of)],
      # A public count of private delivery records, as the moduledoc says.
      authorize?: false
    )
  end

  @doc """
  Adds `:recent_returns` to a query of slots, read from each slot's
  `aggregates`: the responses in the window that carried its Offers.
  """
  @spec count_slot_returns(Ash.Query.t(), {DateTime.t(), DateTime.t()}) :: Ash.Query.t()
  def count_slot_returns(query, {since, as_of}) do
    Ash.Query.aggregate(query, :recent_returns, :count, [:placements, :delivery_items],
      query: [filter: expr(inserted_at >= ^since and inserted_at < ^as_of)],
      # As above.
      authorize?: false
    )
  end

  @doc "Global's opportunities in the window, by slot number."
  @spec global_opportunities({DateTime.t(), DateTime.t()}) :: %{(1..3) => non_neg_integer()}
  def global_opportunities({since, as_of}) do
    Map.new(1..3, fn number ->
      count =
        Delivery
        |> Ash.Query.filter(
          selected_at >= ^since and selected_at < ^as_of and
            fragment("? = ANY(?)", ^number, global_opportunities)
        )
        # As above.
        |> Ash.count!(authorize?: false)

      {number, count}
    end)
  end

  @doc "When counting began: the first delivery on record, or nil before any."
  @spec counting_since() :: DateTime.t() | nil
  # As above: only the earliest time is read, never a record.
  def counting_since, do: Ash.min!(Delivery, :selected_at, authorize?: false)
end
