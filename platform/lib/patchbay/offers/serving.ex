defmodule Patchbay.Offers.Serving do
  @moduledoc """
  Chooses the Offers for a new post's response, never at the post's expense.

  The post has already been written when this runs. If choosing fails, the
  response goes out without Offers, the failure is logged and counted, and
  nothing about the post changes.
  """

  require Logger

  alias Patchbay.Offers.Delivery

  @type post :: %{
          required(:site_id) => Ecto.UUID.t(),
          required(:report_id) => Ecto.UUID.t(),
          required(:reply_id) => Ecto.UUID.t() | nil,
          required(:operation) => :thread | :report | :reply,
          required(:surface) => :http_api | :native_mcp
        }

  @doc """
  The delivery for one new post, with its items, their placements and
  wordings, and the site loaded; or nil when choosing failed.
  """
  @spec after_post(post()) :: Delivery.t() | nil
  def after_post(post) do
    Delivery
    |> Ash.Changeset.for_create(:deliver, post)
    # Patchbay records its own choice; no caller may write one.
    |> Ash.create(authorize?: false, load: [:site])
    |> case do
      {:ok, delivery} ->
        delivery

      {:error, error} ->
        failed(post, error)
    end
  rescue
    error -> failed(post, error)
  end

  defp failed(post, error) do
    :telemetry.execute([:patchbay, :offers, :delivery_failed], %{count: 1}, %{
      surface: post.surface,
      operation: post.operation
    })

    Logger.error(
      "Agent Offers left out of a #{post.operation} response: " <> Exception.message(error)
    )

    nil
  end
end
