defmodule Patchbay.Offers.SlotOrder do
  @moduledoc """
  The order a market's three slots sell in. One open slot is for sale at a
  time: the lowest-numbered one with no Offer showing. The open slots after
  it wait until it is taken. A slot with an Offer showing can always be
  outbid.

  The page, the agents' slot list and `Patchbay.Offers.Bidding` all read
  their answer here, so each says the same.
  """

  @typedoc "A slot's turn: showing an Offer, for sale, or waiting for the slot named."
  @type state :: :showing | :for_sale | {:waiting, 1..3}

  @doc "The slot for sale, given the numbers with an Offer showing; nil when all three show."
  @spec for_sale([1..3]) :: 1..3 | nil
  def for_sale(showing), do: Enum.find(1..3, &(&1 not in showing))

  @doc "Slot `number`'s turn, given the numbers with an Offer showing."
  @spec state(1..3, [1..3]) :: state()
  def state(number, showing) do
    cond do
      number in showing -> :showing
      number == for_sale(showing) -> :for_sale
      true -> {:waiting, for_sale(showing)}
    end
  end
end
