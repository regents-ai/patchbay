defmodule PatchbayWeb.OfferModerationLive do
  @moduledoc """
  The private page where moderators look after Agent Offers: the wordings
  screening left for a person; the reports agents file, newest first, as
  they arrive; the Offers reported most, with the figures that put a count
  in proportion; what screening found; and the decisions already on record.

  A moderator allows or refuses a wording screening could not decide,
  dismisses or confirms a report, or blocks a wording so it is shown nowhere
  from that moment. Each decision is written with its reason
  and the moderator's name in the same transaction as the change. A report's
  note is the reporter's own words and is shown only as text.

  Only a signed-in profile whose verified wallet is on the moderator list
  reaches the page; anyone else is answered as though it does not exist.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.Forum.BoardHTML,
    only: [board_header: 1, count_label: 3, moment: 1, site_name: 1]

  require Ash.Query

  alias Patchbay.Offers.CreativeVersion
  alias Patchbay.Offers.ModerationAction
  alias Patchbay.Offers.OfferReport
  alias Patchbay.Offers.Review
  alias PatchbayWeb.Forum.NotFoundError
  alias PatchbayWeb.Read

  @limit 50

  @figures [:report_count, :reporter_count, :confirmed_count, :delivery_count]

  @impl true
  def mount(_params, _session, socket) do
    if !Patchbay.Config.moderator?(socket.assigns.current_profile), do: raise(NotFoundError)

    if connected?(socket) do
      :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, OfferReport.topic())
      :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, Review.topic())
      :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, Patchbay.Offers.Slot.topic())
    end

    {:ok,
     socket
     |> assign(page_title: "Agent Offers moderation", problem: nil)
     |> assign(board: %Read{owner: :moderators})
     |> Read.settle({Read, :board, 0}, {:ok, read_board()})}
  end

  @impl true
  def handle_info(changed, socket)
      when changed in [:offer_reports_changed, :offer_reviews_changed, :offer_markets_changed],
      do: {:noreply, reread(socket)}

  @impl true
  def handle_event("retry", _params, socket), do: {:noreply, reread(socket)}

  def handle_event("decide", %{"report_id" => id, "decision" => decision} = params, socket) do
    with {:ok, decision} <- decision(decision),
         {:ok, report} <- fetch(OfferReport, id),
         {:ok, _decided} <-
           report
           |> Ash.Changeset.for_update(
             :decide,
             %{
               decision: decision,
               reason: params["reason"],
               idempotency_key: Ecto.UUID.generate()
             },
             actor: socket.assigns.current_profile
           )
           |> Ash.update() do
      {:noreply, assign(socket, problem: nil)}
    else
      {:error, problem} -> {:noreply, assign(socket, problem: words(problem))}
    end
  end

  def handle_event("settle", %{"review_id" => id, "decision" => decision} = params, socket) do
    with {:ok, decision} <- screening_decision(decision),
         {:ok, review} <- fetch(Review, id),
         {:ok, _decided} <-
           review
           |> Ash.Changeset.for_update(
             :decide,
             %{
               decision: decision,
               reason: params["reason"],
               idempotency_key: Ecto.UUID.generate(),
               fresh_for_us: Patchbay.Offers.approval_fresh_for_us()
             },
             actor: socket.assigns.current_profile
           )
           |> Ash.update() do
      {:noreply, socket |> assign(problem: nil) |> reread()}
    else
      {:error, problem} -> {:noreply, assign(socket, problem: words(problem))}
    end
  end

  def handle_event("block", %{"version_id" => id} = params, socket) do
    with {:ok, version} <- fetch(CreativeVersion, id),
         {:ok, _blocked} <-
           version
           |> Ash.Changeset.for_update(
             :block,
             %{reason: params["reason"], idempotency_key: Ecto.UUID.generate()},
             actor: socket.assigns.current_profile
           )
           |> Ash.update() do
      {:noreply, socket |> assign(problem: nil) |> reread()}
    else
      {:error, problem} -> {:noreply, assign(socket, problem: words(problem))}
    end
  end

  def handle_event(
        "remove",
        %{"placement_id" => id, "generation" => generation, "reason" => reason} = params,
        socket
      ) do
    case Patchbay.Offers.remove_placement(
           %{
             placement_id: id,
             expected_generation: generation,
             reason: reason,
             no_refund: params["no_refund"] == "true",
             # One removal of one placement: pressing again answers with
             # the decision already made.
             idempotency_key: "remove:#{id}:#{generation}"
           },
           actor: socket.assigns.current_profile
         ) do
      {:ok, _decision} -> {:noreply, socket |> assign(problem: nil) |> reread()}
      {:error, problem} -> {:noreply, assign(socket, problem: words(problem))}
    end
  end

  @impl true
  def handle_async({Read, :board, _generation} = name, result, socket),
    do: {:noreply, Read.settle(socket, name, result)}

  defp reread(socket), do: Read.start(socket, :board, :moderators, &read_board/0)

  defp decision("dismissed"), do: {:ok, :dismissed}
  defp decision("confirmed"), do: {:ok, :confirmed}
  defp decision(_other), do: {:error, "That is not a decision this page makes."}

  defp screening_decision("allow"), do: {:ok, :allow}
  defp screening_decision("deny"), do: {:ok, :deny}
  defp screening_decision(_other), do: {:error, "That is not a decision this page makes."}

  # The page is the moderator's own door: it reads every report and wording
  # whoever owns them, so these reads skip policy deliberately after the
  # moderator check in `mount/3`. Every change goes through its action's
  # moderator policy.
  defp fetch(resource, id) do
    case Ash.get(resource, id, authorize?: false) do
      {:ok, record} -> {:ok, record}
      {:error, _missing} -> {:error, "That record does not exist."}
    end
  end

  defp words(problem) when is_binary(problem), do: problem

  defp words(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, " ", fn
      %{field: field, message: message} when not is_nil(field) -> "#{field} #{message}."
      error -> Exception.message(error)
    end)
  end

  defp words(%Ash.Error.Forbidden{}), do: "Only a moderator can do that."

  defp words(_problem), do: "That could not be saved. Try again in a moment."

  defp read_board do
    {:ok,
     %{
       waiting: waiting(),
       reports: reports(),
       ranking: ranking(),
       decisions: decisions(),
       screening: screening()
     }}
  end

  # Moderator reads, as above.
  defp reports do
    reviews = Review |> Ash.Query.sort(inserted_at: :desc) |> Ash.Query.load(market: :site)

    OfferReport
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(@limit)
    |> Ash.Query.load(
      version: [{:reviews, reviews} | @figures],
      placement: [slot: [next_bid: [:version], market: :site]]
    )
    |> Ash.read!(authorize?: false)
  end

  # As above. Oldest first: the advertiser has waited longest.
  defp waiting do
    Review
    |> Ash.Query.filter(decision == :needs_review)
    |> Ash.Query.sort(decided_at: :asc)
    |> Ash.Query.limit(@limit)
    |> Ash.Query.load([:version, market: :site])
    |> Ash.read!(authorize?: false)
  end

  # As above.
  defp ranking do
    CreativeVersion
    |> Ash.Query.load(@figures)
    |> Ash.Query.filter(report_count > 0)
    |> Ash.Query.sort(report_count: :desc, inserted_at: :asc)
    |> Ash.Query.limit(@limit)
    |> Ash.read!(authorize?: false)
  end

  # As above.
  defp decisions do
    ModerationAction
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(@limit)
    |> Ash.Query.load(:moderator)
    |> Ash.read!(authorize?: false)
  end

  # As above.
  defp screening do
    %{
      waiting:
        Ash.count!(Ash.Query.filter(Review, not is_nil(screen_requested_at)), authorize?: false),
      needs_person:
        Ash.count!(Ash.Query.filter(Review, decision == :needs_review), authorize?: false)
    }
  end

  @doc false
  def reason_label(:malicious_link), do: "Harmful link"
  def reason_label(:prompt_injection), do: "Tries to steer the agent"
  def reason_label(:impersonation), do: "Impersonation"
  def reason_label(:misleading), do: "Misleading"
  def reason_label(:irrelevant_placement), do: "Does not fit the board"
  def reason_label(:other), do: "Other"

  @doc false
  def reporter_label("profile:" <> _id), do: "A signed-in agent"
  def reporter_label("session:" <> _id), do: "A visitor"

  @doc false
  def surface_label(:http_api), do: "on the website or its API"
  def surface_label(:native_mcp), do: "over the hosted connection"

  @doc false
  def status_label(:open), do: "Open"
  def status_label(:dismissed), do: "Dismissed"
  def status_label(:confirmed), do: "Confirmed"

  @doc false
  def review_label(%{kind: :safety}), do: "Safety check"
  def review_label(%{kind: :relevance, market: %{site: site}}), do: "Fit for #{site_name(site)}"

  @doc false
  def reason_words(code), do: Patchbay.Offers.Screening.reason_words(code)

  @doc false
  def review_decision_label(:pending), do: "waiting"
  def review_decision_label(:allow), do: "allowed"
  def review_decision_label(:deny), do: "refused"
  def review_decision_label(:needs_review), do: "needs a person"

  @doc false
  def slot_label(%{slot: %{number: number, market: %{scope: :global}}}),
    do: "Global · Slot #{number}"

  def slot_label(%{slot: %{number: number, market: %{site: site}}}),
    do: "Site · Slot #{number} on #{site_name(site)}"

  @doc false
  def figures(version) do
    "#{count_label(version.report_count, "report", "reports")} from " <>
      "#{count_label(version.reporter_count, "reporter", "reporters")}, " <>
      "#{version.confirmed_count} confirmed, shown " <>
      "#{count_label(version.delivery_count, "time", "times")}" <> per_thousand(version)
  end

  defp per_thousand(%{delivery_count: 0}), do: ""

  defp per_thousand(%{report_count: reports, delivery_count: shown}),
    do: " (#{:erlang.float_to_binary(reports * 1000 / shown, decimals: 1)} per 1,000 shown)"

  @doc "What happens to the slot's waiting next-period bid if the Offer is removed."
  def successor_words(nil), do: "Nothing is waiting, so the slot will be empty."

  def successor_words(%{version: %{blocked_at: blocked}}) when not is_nil(blocked),
    do: "The waiting next-period bid's wording is blocked, so it will not start."

  def successor_words(bid),
    do:
      "The waiting next-period bid of #{PatchbayWeb.OffersLive.Markets.credits(bid.amount_minor)} " <>
        "starts at once if its wording may still be shown."

  @doc false
  def decision_label(:dismiss_report), do: "Dismissed a report"
  def decision_label(:confirm_report), do: "Confirmed a report"
  def decision_label(:block_version), do: "Blocked a wording"
  def decision_label(:remove_placement), do: "Removed a placement"
  def decision_label(:allow_version), do: "Allowed a wording"
  def decision_label(:refuse_version), do: "Refused a wording"
end
