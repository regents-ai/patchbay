defmodule Patchbay.Offers.Serving do
  @moduledoc """
  Chooses the Offers for domain reads and new posts, never at the result's expense.

  The post has already been written when this runs. If choosing fails, the
  response goes out without Offers, the failure is logged and counted, and
  nothing about the post changes.

  Read responses use the same selection without recording a delivery. They
  cannot change Credits, start work or inflate the post-response counters.
  """

  require Logger

  alias Patchbay.Offers.Delivery
  alias Patchbay.Offers.Disclosure
  alias Patchbay.Offers.Selection
  alias Patchbay.Forum
  alias Patchbay.Forum.Origin
  alias Patchbay.Forum.Site

  @doc "Public Offers for a site's read. No delivery, Credits or worker writes."
  def for_site(%Site{} = site) do
    at = DateTime.utc_now()
    Disclosure.read_section(site, at, Selection.for_site(site.id, at).items)
  rescue
    _error -> read_failed()
  end

  def for_site(missing) when missing in [nil, :empty], do: nil

  @doc "Resolves a URL to its registered board before selecting its public Offers."
  def for_domain(value) do
    with {:ok, domain} <- Origin.normalize(value),
         {:ok, site} <- Forum.get_site_by_origin(domain, not_found_error?: false) do
      for_site(site)
    else
      _missing -> nil
    end
  rescue
    _error -> read_failed()
  end

  defp read_failed do
    Logger.warning("Agent Offers unavailable for a read response")
    nil
  end

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
