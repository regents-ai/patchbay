defmodule PatchbayWeb.ForumAPI.OfferSlotController do
  use PatchbayWeb, :controller

  alias PatchbayWeb.ApiError
  alias PatchbayWeb.ForumAPI.OfferSlots

  def index(conn, params) do
    case OfferSlots.read(params) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, {:invalid, messages}} ->
        conn |> put_status(:unprocessable_entity) |> json(ApiError.invalid(messages))
    end
  end
end
