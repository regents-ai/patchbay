defmodule PatchbayWeb.OffersLive.Create do
  @moduledoc """
  An advertiser's own Offers: write a new one, see it checked as it is
  typed, and follow each saved Offer through screening.

  The check as you type is the same rule the save applies
  (`Patchbay.Offers.CreativeText`), so the counts, the links found and the
  preview are exactly what will be kept and shown. A change of wording is
  saved as a new version, screened again, and never alters a version that
  is already bid or showing.

  A visitor who is not signed in is told how to start; nothing here is
  shown to anyone but the Offers' owner.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1, moment: 1, site_name: 1]

  alias Patchbay.Offers
  alias Patchbay.Offers.CreativeText
  alias Patchbay.Offers.Disclosure
  alias Patchbay.Offers.Review
  alias Patchbay.Offers.Screening

  @impl true
  def mount(_params, _session, socket) do
    profile = socket.assigns.current_profile

    if profile && connected?(socket),
      do: :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, Review.topic())

    {:ok,
     socket
     |> assign(page_title: "Your Offers", problem: nil, rewording: nil)
     |> assign_new_offer(%{"label" => "", "text" => ""})
     |> assign(saved: if(profile, do: saved(profile), else: []))}
  end

  @impl true
  def handle_info(:offer_reviews_changed, socket),
    do: {:noreply, assign(socket, saved: saved(socket.assigns.current_profile))}

  @impl true
  def handle_event("check", %{"offer" => params}, socket),
    do: {:noreply, assign_new_offer(socket, params)}

  def handle_event("save", %{"offer" => %{"label" => label, "text" => text} = params}, socket) do
    profile = socket.assigns.current_profile

    case Offers.create_creative(label, text, actor: profile) do
      {:ok, _creative} ->
        {:noreply,
         socket
         |> assign(problem: nil, saved: saved(profile))
         |> assign_new_offer(%{"label" => "", "text" => ""})}

      {:error, error} ->
        {:noreply, socket |> assign(problem: words(error)) |> assign_new_offer(params)}
    end
  end

  def handle_event("reword", %{"creative_id" => id}, socket) do
    creative = Enum.find(socket.assigns.saved, &(&1.id == id))

    {:noreply,
     assign(socket,
       rewording: %{id: id, text: creative.current_version.text},
       problem: nil
     )}
  end

  def handle_event("check_reword", %{"reword" => %{"text" => text}}, socket),
    do: {:noreply, update(socket, :rewording, &%{&1 | text: text})}

  def handle_event("cancel_reword", _params, socket),
    do: {:noreply, assign(socket, rewording: nil, problem: nil)}

  def handle_event("save_reword", %{"reword" => %{"creative_id" => id, "text" => text}}, socket) do
    profile = socket.assigns.current_profile

    case Offers.save_creative_version(id, text, actor: profile) do
      {:ok, _version} ->
        {:noreply, assign(socket, rewording: nil, problem: nil, saved: saved(profile))}

      {:error, error} ->
        {:noreply,
         socket |> assign(problem: words(error)) |> assign(rewording: %{id: id, text: text})}
    end
  end

  defp assign_new_offer(socket, params) do
    assign(socket,
      new_offer: to_form(params, as: :offer),
      new_check: check(params["text"] || "")
    )
  end

  defp saved(profile) do
    reviews = Ash.Query.load(Review, [:approved?, market: :site])

    Offers.my_creatives!(
      actor: profile,
      load: [current_version: [reviews: reviews], versions: [reviews: reviews]]
    )
    |> Enum.reject(& &1.archived_at)
  end

  @doc "Why an Offer or a new wording was not saved, in words."
  def words(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, " ", fn
      %{field: :text, message: message} -> "The wording #{message}."
      %{field: :label, message: message} -> "The name #{message}."
      %{field: :creative_id, message: message} -> "That Offer #{message}."
      error -> Exception.message(error)
    end)
  end

  def words(_problem), do: "That could not be saved. Try again in a moment."

  @doc """
  The text as it will be kept, its counts and its links, or what is wrong
  with it: the same rule the save applies.
  """
  def check(text) do
    case CreativeText.normalize(text) do
      {:ok, kept} ->
        %{
          text: kept,
          problem: nil,
          code_points: CreativeText.code_points(kept),
          bytes: byte_size(kept),
          urls: CreativeText.urls(kept),
          bare_addresses: CreativeText.bare_addresses(kept)
        }

      {:error, reason} ->
        %{
          text: nil,
          problem: if(text == "", do: nil, else: "The wording #{CreativeText.problem(reason)}."),
          code_points: if(String.valid?(text), do: CreativeText.code_points(text), else: 0),
          bytes: byte_size(text),
          urls: [],
          bare_addresses: []
        }
    end
  end

  @doc "The Offer as a text-only reader would get it, in a first site slot ending in 72 hours."
  def preview(text) do
    expires_at = DateTime.utc_now() |> DateTime.add(72, :hour) |> DateTime.truncate(:second)
    Disclosure.heading() <> "\n" <> Disclosure.line("Site · Slot 1", expires_at, text)
  end

  attr(:check, :map, required: true)

  @doc "What a wording being typed will be: its links, any bare address, and its preview."
  def offer_check(assigns) do
    ~H"""
    <div :if={@check.text} class="pb-offers-check">
      <p :if={@check.urls != []} class="pb-offmod-figures">
        Links screening will visit: {Enum.join(@check.urls, ", ")}
      </p>
      <p :if={@check.bare_addresses != []} class="pb-offmod-figures">
        Not written as a full link, so a person checks it: {Enum.join(@check.bare_addresses, ", ")}
      </p>
      <p class="patchbay-muted">How an agent will get it:</p>
      <pre class="pb-offers-preview">{preview(@check.text)}</pre>
    </div>
    """
  end

  attr(:version, :map, required: true)

  @doc "One saved wording: its text, counts, links and where screening stands."
  def offer_version(assigns) do
    ~H"""
    <blockquote class="pb-offmod-offer">{@version.text}</blockquote>
    <p class="pb-offmod-figures">
      {@version.code_points} of {max_code_points()} characters · {@version.byte_count} of {max_bytes()} bytes
      <span :if={@version.urls != []}>· links: {Enum.join(@version.urls, ", ")}</span>
      <span :if={@version.bare_addresses != []}>
        · not full links: {Enum.join(@version.bare_addresses, ", ")}
      </span>
    </p>
    <p :if={@version.blocked_at} class="pb-offmod-blocked">
      Blocked by a moderator on {moment(@version.blocked_at)}. It cannot be shown again.
    </p>
    <ul class="pb-offers-standing">
      <li :for={review <- @version.reviews}>
        <strong>{review_label(review)}:</strong> {standing(review)}
        <span :for={code <- review.reason_codes}>{reason_words(code)}</span>
      </li>
    </ul>
    """
  end

  @doc false
  def max_code_points, do: CreativeText.max_code_points()

  @doc false
  def max_bytes, do: CreativeText.max_bytes()

  @doc "Where one screening of a wording stands, in words."
  def standing(%{decision: :pending}), do: "Waiting for screening."

  def standing(%{decision: :allow, approved?: true, fresh_until: until}),
    do: "Allowed until #{moment(until)}, then screened again."

  def standing(%{decision: :allow}), do: "Allowed before; screened again before it can be shown."

  def standing(%{decision: :deny}), do: "Refused."
  def standing(%{decision: :needs_review}), do: "A person at Patchbay is checking it."

  @doc false
  def review_label(%{kind: :safety}), do: "Safety"
  def review_label(%{kind: :relevance, market: %{site: site}}), do: "Fit for #{site_name(site)}"

  @doc false
  def reason_words(code), do: Screening.reason_words(code)
end
