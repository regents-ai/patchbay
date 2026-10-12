defmodule PatchbayWeb.OffersLive.Create do
  @moduledoc """
  An advertiser's own Offers: write a new one, see it checked as it is
  typed, follow each saved Offer through screening, and delete one that
  was never bid with.

  The check as you type is the same rule the save applies
  (`Patchbay.Offers.CreativeText`), so the counts, the links found and the
  preview are exactly what will be kept and shown. A change of wording is
  saved as a new version, screened again, and never alters a version that
  is already bid or showing.

  A visitor who is not signed in is told how to start; nothing here is
  shown to anyone but the Offers' owner.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.OffersLive.Navigation, only: [offers_header: 1]

  import PatchbayWeb.Forum.BoardHTML, only: [moment: 1, site_name: 1]

  alias Patchbay.Offers
  alias Patchbay.Offers.CreativeText
  alias Patchbay.Offers.Disclosure
  alias Patchbay.Offers.Review
  alias Patchbay.Offers.Screening

  embed_templates "create/*"

  @not_saved "That could not be saved. Try again in a moment."
  @not_deleted "That Offer could not be deleted. Try again in a moment."

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, socket |> initialize_editor() |> assign(page_title: "Your Offers")}

  @impl true
  def handle_params(params, uri, socket),
    do: {:noreply, editor_params(socket, params, uri)}

  @doc "Initialize the shared Offer editor on its hosting page's socket."
  def initialize_editor(socket) do
    profile = socket.assigns.current_profile

    if profile && connected?(socket),
      do: :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, Review.topic())

    socket
    |> assign(
      problem: nil,
      rewording: nil,
      deleting: nil,
      screening_paused?: Offers.screening_paused?()
    )
    |> assign_new_offer(blank_offer())
    |> assign(saved: if(profile, do: saved(profile), else: []))
  end

  @doc """
  Takes the editor's state from the page address, so a reload or a
  reconnect shows the same form and the browser restores what was typed in
  it. `"reword"` names the saved Offer being reworded and `"delete"` the one
  whose deletion is being confirmed; only the signed-in account's own saved
  Offers open either, and only one never bid with can be deleted, so any
  other id shows nothing.
  """
  def editor_params(socket, params, uri) do
    socket
    |> assign(editor_uri: uri)
    |> choose(params["reword"])
    |> choose_deletion(params["delete"])
  end

  @doc "Moves to the same page with `changes` made to its address; a `nil` value drops that key."
  def patch_editor(socket, changes) do
    uri = URI.parse(socket.assigns.editor_uri)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.merge(changes)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    query = if query == %{}, do: nil, else: URI.encode_query(query)
    push_patch(socket, to: URI.to_string(%URI{path: uri.path, query: query}))
  end

  # The same Offer chosen again keeps what is being typed for it.
  defp choose(%{assigns: %{rewording: %{id: id}}} = socket, id), do: socket

  defp choose(socket, creative_id) do
    case Enum.find(socket.assigns.saved, &(&1.id == creative_id)) do
      nil ->
        assign(socket, rewording: nil)

      creative ->
        assign(socket,
          rewording: %{
            id: creative.id,
            text: creative.current_version.text,
            request_key: request_key()
          }
        )
    end
  end

  defp choose_deletion(socket, creative_id) do
    deleting = Enum.find(socket.assigns.saved, &(&1.id == creative_id and not &1.has_bids?))
    assign(socket, deleting: deleting)
  end

  # Each form carries the key for the one save it is for. A retry of the same
  # form, after a lost answer or a reconnect, sends the same key and gets the
  # first save back; a form starts again with a new key once it has saved.
  defp blank_offer, do: %{"label" => "", "text" => "", "request_key" => request_key()}

  defp request_key, do: Ecto.UUID.generate()

  @impl true
  def handle_info(:offer_reviews_changed, socket),
    do: {:noreply, assign(socket, saved: saved(socket.assigns.current_profile))}

  # Each event names exactly the fields its form sends. A malformed or stale
  # one (a missing field, or wording for an Offer that is no longer being
  # reworded) changes nothing and never stops the page.
  @impl true
  def handle_event(
        "check",
        %{"offer" => %{"label" => label, "text" => text, "request_key" => key}},
        socket
      )
      when is_binary(label) and is_binary(text) and is_binary(key),
      do:
        {:noreply,
         assign_new_offer(socket, %{"label" => label, "text" => text, "request_key" => key})}

  def handle_event(
        "save",
        %{"offer" => %{"label" => label, "text" => text, "request_key" => key}},
        socket
      )
      when is_binary(label) and is_binary(text) and is_binary(key) do
    profile = socket.assigns.current_profile

    case Offers.create_creative(label, text, key, actor: profile) do
      {:ok, _creative} ->
        {:noreply,
         socket
         |> assign(problem: nil, saved: saved(profile))
         |> assign_new_offer(blank_offer())}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(problem: words(error))
         |> assign_new_offer(%{"label" => label, "text" => text, "request_key" => key})}
    end
  end

  def handle_event("reword", %{"creative_id" => id}, socket) when is_binary(id) do
    if Enum.any?(socket.assigns.saved, &(&1.id == id)),
      do: {:noreply, socket |> assign(problem: nil) |> patch_editor(%{"reword" => id})},
      else: {:noreply, assign(socket, problem: "That Offer is no longer available.")}
  end

  def handle_event(
        "check_reword",
        %{"reword" => %{"creative_id" => id, "text" => text, "request_key" => key}},
        %{assigns: %{rewording: %{id: id}}} = socket
      )
      when is_binary(text) and is_binary(key),
      do: {:noreply, assign(socket, rewording: %{id: id, text: text, request_key: key})}

  def handle_event("cancel_reword", _params, socket),
    do: {:noreply, socket |> assign(problem: nil) |> patch_editor(%{"reword" => nil})}

  def handle_event(
        "save_reword",
        %{"reword" => %{"creative_id" => id, "text" => text, "request_key" => key}},
        %{assigns: %{rewording: %{id: id}}} = socket
      )
      when is_binary(text) and is_binary(key) do
    profile = socket.assigns.current_profile

    case Offers.save_creative_version(id, text, key, actor: profile) do
      {:ok, _version} ->
        {:noreply,
         socket
         |> assign(problem: nil, saved: saved(profile))
         |> patch_editor(%{"reword" => nil})}

      {:error, error} ->
        {:noreply,
         assign(socket,
           problem: words(error),
           rewording: %{id: id, text: text, request_key: key}
         )}
    end
  end

  def handle_event("ask_delete", %{"creative_id" => id}, socket) when is_binary(id),
    do: {:noreply, socket |> assign(problem: nil) |> patch_editor(%{"delete" => id})}

  def handle_event("cancel_delete", _params, socket),
    do: {:noreply, patch_editor(socket, %{"delete" => nil})}

  # Deletes only the Offer the open confirmation names. The action checks
  # again that it is the account's own and was never bid with.
  def handle_event("delete", %{"creative_id" => id}, %{assigns: %{deleting: %{id: id}}} = socket) do
    profile = socket.assigns.current_profile

    case Offers.delete_creative(socket.assigns.deleting, actor: profile) do
      :ok ->
        {:noreply,
         socket
         |> assign(problem: nil, saved: saved(profile), deleting: nil)
         |> patch_editor(%{"delete" => nil, "reword" => nil})}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(problem: deletion_words(error), saved: saved(profile))
         |> patch_editor(%{"delete" => nil})}
    end
  end

  def handle_event("delete", _params, socket),
    do: {:noreply, socket |> assign(problem: @not_deleted) |> patch_editor(%{"delete" => nil})}

  def handle_event(event, _params, socket) when event in ["save", "save_reword"],
    do: {:noreply, assign(socket, problem: @not_saved)}

  def handle_event(event, _params, socket)
      when event in ["check", "reword", "check_reword", "ask_delete"],
      do: {:noreply, socket}

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
      load: [
        :has_bids?,
        current_version: [:blocked_at, reviews: reviews],
        versions: [:blocked_at, reviews: reviews]
      ]
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

  def words(_problem), do: @not_saved

  defp deletion_words(%Ash.Error.Invalid{errors: [%{field: :id, message: message} | _rest]}),
    do: "That Offer #{message}."

  defp deletion_words(_problem), do: @not_deleted

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
    <details
      class="pb-bid-details pb-offers-check"
      data-empty={is_nil(@check.text)}
      inert={is_nil(@check.text)}
    >
      <summary>Preview &amp; links</summary>
      <p :if={@check.urls != []} class="pb-offmod-figures">
        Links screening will visit: {Enum.join(@check.urls, ", ")}
      </p>
      <p :if={@check.bare_addresses != []} class="pb-offmod-figures">
        Addresses screening will open as https links: {Enum.join(@check.bare_addresses, ", ")}
      </p>
      <pre :if={@check.text} class="pb-offers-preview">{preview(@check.text)}</pre>
    </details>
    """
  end

  attr(:version, :map, required: true)

  @doc "One saved wording: its text, counts, links and where screening stands."
  def offer_version(assigns) do
    ~H"""
    <blockquote class="pb-offmod-offer">{@version.text}</blockquote>
    <ul class="pb-offers-review-states" aria-label="Approval status">
      <li :for={review <- @version.reviews} data-decision={review.decision}>
        <span>{review_label(review)}</span><strong>{review_state(review)}</strong>
      </li>
    </ul>
    <p :if={@version.blocked_at} class="pb-offmod-blocked">
      Blocked by Patchbay. It cannot be shown again.
    </p>
    <details class="pb-bid-details">
      <summary>Screening details</summary>
      <p class="pb-offmod-figures">
        {@version.code_points} of {max_code_points()} characters · {@version.byte_count} of {max_bytes()} bytes
        <span :if={@version.urls != []}>· links: {Enum.join(@version.urls, ", ")}</span>
        <span :if={@version.bare_addresses != []}>
          · opened as https links: {Enum.join(@version.bare_addresses, ", ")}
        </span>
      </p>
      <ul class="pb-offers-standing">
        <li :for={review <- @version.reviews}>
          <strong>{review_label(review)}:</strong> {standing(review)}
          <span :for={code <- review.reason_codes}>{reason_words(code)}</span>
        </li>
      </ul>
    </details>
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

  def standing(%{decision: :deny}), do: "Turned down."

  defp review_state(%{decision: :allow, approved?: true}), do: "Ready"
  defp review_state(%{decision: :allow}), do: "Recheck needed"
  defp review_state(%{decision: :pending}), do: "Waiting"
  defp review_state(%{decision: :deny}), do: "Turned down"

  @doc false
  def review_label(%{kind: :safety}), do: "Safety"
  def review_label(%{kind: :relevance, market: %{site: site}}), do: "Fit for #{site_name(site)}"

  @doc false
  def reason_words(code), do: Screening.reason_words(code)
end
