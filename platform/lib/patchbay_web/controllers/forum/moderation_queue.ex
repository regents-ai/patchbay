defmodule PatchbayWeb.Forum.ModerationQueue do
  @moduledoc """
  What the moderation page lists: the records held for a decision, the posts
  turned away before they were published (`Patchbay.Forum.PostReview`), the
  newest published threads, and the decisions on record.

  These reads take in records every public read leaves out, which is the
  point of the page, so only its door calls them: the page
  (`PatchbayWeb.Forum.ModerationController`, behind
  `PatchbayWeb.Plugs.RequireModerator`) and its live part
  (`PatchbayWeb.ModerationLive`, behind `PatchbayWeb.Moderators`).
  """

  import Ash.Query, only: [sort: 2, limit: 2]

  alias Patchbay.Forum.ModerationAction
  alias Patchbay.Forum.PostReview
  alias Patchbay.Forum.Reply
  alias Patchbay.Forum.Report

  @review_limit 50

  @doc "Everything the page lists, read now."
  @spec read() :: %{
          quarantined: [{:thread, Report.t()} | {:reply, Reply.t()}],
          turned_away: [PostReview.entry()],
          latest: [Report.t()],
          decisions: [ModerationAction.t()]
        }
  def read do
    %{
      quarantined: quarantined(),
      turned_away: PostReview.turned_away(),
      latest: latest(),
      decisions: decisions()
    }
  end

  @doc "The threads and replies held for a decision, newest first."
  @spec quarantined() :: [{:thread, Report.t()} | {:reply, Reply.t()}]
  def quarantined do
    # Internal reads behind the moderator gate: they deliberately include
    # records public actions filter out.
    threads =
      Report
      |> Ash.Query.filter(visibility == :quarantined)
      |> sort(last_activity_at: :desc)
      |> limit(@review_limit)
      |> Ash.read!(authorize?: false, load: [:site, :author])

    replies =
      Reply
      |> Ash.Query.filter(visibility == :quarantined)
      |> sort(inserted_at: :desc)
      |> limit(@review_limit)
      |> Ash.read!(authorize?: false, load: [:author, :report])

    Enum.map(threads, &{:thread, &1}) ++ Enum.map(replies, &{:reply, &1})
  end

  @doc "The newest published threads, by their last activity."
  @spec latest() :: [Report.t()]
  def latest do
    Report
    |> Ash.Query.filter(visibility == :published)
    |> sort(last_activity_at: :desc)
    |> limit(@review_limit)
    # Internal read behind the moderator gate, as above.
    |> Ash.read!(authorize?: false, load: [:site, :author])
  end

  @doc "The newest decisions on record."
  @spec decisions() :: [ModerationAction.t()]
  def decisions do
    ModerationAction
    |> sort(inserted_at: :desc)
    |> limit(50)
    # The audit log's policies deny everyone; this read is the door's own.
    |> Ash.read!(authorize?: false)
  end
end
