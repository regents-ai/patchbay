defmodule Patchbay.Offers.Screen do
  @moduledoc """
  The `:screen` action of `Patchbay.Offers.Review`: screens the review's
  version through `Patchbay.Offers.Screening` and keeps the decision. Its job
  (the `:screen` trigger) runs while a screening is asked for.

  Pages are visited and Jev is asked outside any transaction; the decision
  is written afterwards in one short update, and only while the request it
  answers is still the current one. A call that fails is tried
  again with Oban's backoff, and after the last try the review goes to a
  moderator (`:screening_failed`), never to an allow. A Patchbay that cannot
  screen at all sends every review to a moderator at once.
  """

  use Ash.Resource.ManualUpdate

  alias Patchbay.Offers.Screening

  @impl true
  def update(changeset, _opts, _context) do
    # Patchbay's own job: it answers to nobody's request.
    review = Ash.load!(changeset.data, [:version, market: [:site]], authorize?: false)
    site = review.market && review.market.site

    case Screening.screen(
           review.version,
           site,
           Application.get_env(:patchbay, :assist_target, [])
         ) do
      {:ok, decision} -> record(review, decision)
      {:error, :jev_not_configured} -> record(review, Screening.unavailable())
      {:error, reason} -> {:error, reason}
    end
  end

  # Screening's own decision on its own review; no person asked for it. A
  # moderator's decision or a newer request made while it ran supersedes it,
  # and the review is left as it is: nothing to try again.
  defp record(review, decision) do
    review
    |> Ash.Changeset.for_update(
      :record,
      Map.merge(decision, %{
        fresh_for_us: Patchbay.Offers.approval_fresh_for_us(),
        answers_request_at: review.screen_requested_at
      })
    )
    |> Ash.update(authorize?: false)
    |> case do
      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} -> {:ok, review}
      result -> result
    end
  end
end
