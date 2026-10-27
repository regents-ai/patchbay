defmodule PatchbayWeb.Forum.ModerationController do
  @moduledoc """
  The private page where a moderator decides what may be shown.

  Every decision lands in `Forum.moderate/4`, which changes the record's
  visibility and writes the audit row naming who decided and why in one
  transaction. The page itself is the only way in: it lists the board as
  moderators need to see it — quarantined records waiting for a decision,
  the newest published activity, and the decisions already on record.

  It also lists the posts turned away before they were published, with the
  words that were refused. A moderator rules on one, makes a ruled one an
  example for the reader, or lifts a person's pause, each through
  `Patchbay.Forum.PostReview`. A press carries the row's id and nothing of
  its words.
  """

  use PatchbayWeb, :controller

  import Ash.Query, only: [sort: 2, limit: 2]

  alias Patchbay.Forum
  alias Patchbay.Forum.ModerationAction
  alias Patchbay.Forum.PostReview
  alias Patchbay.Forum.Reply
  alias Patchbay.Forum.Report

  @review_limit 50

  plug PatchbayWeb.Plugs.RequireModerator

  def index(conn, _params) do
    conn
    |> merge_assigns(PatchbayWeb.PublicDocuments.page("/moderation"))
    |> render(:index,
      quarantined: load_quarantined(),
      turned_away: PostReview.turned_away(),
      latest: load_latest(),
      decisions: load_decisions(),
      problem: nil
    )
  end

  def decide(conn, %{"subject" => %{"kind" => "post", "id" => id, "action" => action}}) do
    moderator = conn.assigns.current_profile

    case action do
      "right" -> PostReview.rule(id, :right, moderator)
      "wrong" -> PostReview.rule(id, :wrong, moderator)
      "none" -> PostReview.rule(id, :none, moderator)
      "example" -> PostReview.use_as_example(id, moderator)
      "no_example" -> PostReview.drop_example(id, moderator)
      _other -> {:error, "That is not a decision this page makes."}
    end
    |> answered(conn)
  end

  def decide(conn, %{"subject" => %{"kind" => "person", "id" => id, "action" => "lift"}}) do
    id |> PostReview.lift_pause(conn.assigns.current_profile) |> answered(conn)
  end

  def decide(conn, %{"subject" => %{"kind" => kind, "id" => id} = subject}) do
    with {:ok, action} <- moderation_action(subject["action"]),
         {:ok, record} <- fetch_subject(kind, id),
         {:ok, _updated} <-
           Forum.moderate(record, action, reason(subject["reason"]), conn.assigns.current_profile) do
      redirect(conn, to: ~p"/moderation")
    else
      {:error, problem} ->
        conn
        |> put_flash(:error, problem)
        |> redirect(to: ~p"/moderation")
    end
  end

  def decide(conn, _params) do
    conn
    |> put_flash(:error, "Nothing to decide arrived with that.")
    |> redirect(to: ~p"/moderation")
  end

  defp answered({:ok, _done}, conn), do: redirect(conn, to: ~p"/moderation")

  defp answered({:error, problem}, conn) do
    conn
    |> put_flash(:error, problem)
    |> redirect(to: ~p"/moderation")
  end

  defp moderation_action("quarantine"), do: {:ok, :quarantine}
  defp moderation_action("publish"), do: {:ok, :publish}
  defp moderation_action("redact"), do: {:ok, :redact}
  defp moderation_action(_other), do: {:error, "That is not a decision this page makes."}

  defp fetch_subject("thread", id), do: fetch(Report, id)
  defp fetch_subject("reply", id), do: fetch(Reply, id)
  defp fetch_subject(_kind, _id), do: {:error, "That is not something moderation touches."}

  # Moderation reads records regardless of visibility — that is the point of
  # the page — through reads only this door makes. The allowlist check is the
  # plug's; these reads skip policy because their subjects are deny-all.
  defp fetch(resource, id) do
    case resource
         |> Ash.Query.filter(id == ^id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, "That record does not exist."}
      {:ok, record} -> {:ok, record}
      {:error, _failure} -> {:error, "That record could not be read."}
    end
  end

  defp reason(nil), do: "No reason given."
  defp reason(text) when is_binary(text), do: String.slice(String.trim(text), 0, 500)
  defp reason(_other), do: "No reason given."

  defp load_quarantined do
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

  defp load_latest do
    Report
    |> Ash.Query.filter(visibility == :published)
    |> sort(last_activity_at: :desc)
    |> limit(@review_limit)
    # Internal read behind the moderator gate, as above.
    |> Ash.read!(authorize?: false, load: [:site, :author])
  end

  defp load_decisions do
    ModerationAction
    |> sort(inserted_at: :desc)
    |> limit(50)
    # The audit log's policies deny everyone; this read is the door's own.
    |> Ash.read!(authorize?: false)
  end
end
