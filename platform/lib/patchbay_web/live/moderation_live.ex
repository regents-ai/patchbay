defmodule PatchbayWeb.ModerationLive do
  @moduledoc """
  The moderation page's lists and the decisions made on them, where the page
  stands (`/moderation`, drawn by `PatchbayWeb.Forum.ModerationController`).

  Only a moderator reaches it. The page's door lets them in, and the sign-in
  and the moderator list are read again before every press
  (`PatchbayWeb.CurrentProfile`, `PatchbayWeb.Moderators`): anyone else is
  sent to the front page and nothing is decided. Each press acts as the
  moderator as they read now: holding, putting back or removing a record
  through `Patchbay.Forum.moderate/4`, and ruling on a post turned away,
  making it an example or lifting a person's pause through
  `Patchbay.Forum.PostReview`. A press carries the row's id and nothing of
  its words.

  A decision made, the lists are read again; one refused says why beside
  what was pressed. Drawn with the page, the lists are the ones the page has
  just read (`assign_new/3` finds them in the page's assigns); a live
  connection reads them again, once.
  """
  use PatchbayWeb, :live_view

  import PatchbayWeb.Forum.BoardHTML, only: [press_refused: 1]

  require Ash.Query

  import PatchbayWeb.Forum.ModerationHTML,
    only: [
      subject_label: 1,
      subject_path: 2,
      subject_text: 1,
      turned_away_kind: 1,
      finding: 1,
      sure: 1,
      person_name: 1,
      words: 1,
      example_cut: 1,
      until: 1
    ]

  alias Patchbay.Forum
  alias Patchbay.Forum.PostReview
  alias Patchbay.Forum.Reply
  alias Patchbay.Forum.Report
  alias PatchbayWeb.Forum.ModerationQueue

  on_mount {PatchbayWeb.CurrentProfile, :default}
  on_mount PatchbayWeb.Moderators

  @not_a_decision "That is not a decision this page makes."

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(refused: %{})
      |> assign_new(:quarantined, &ModerationQueue.quarantined/0)
      |> assign_new(:turned_away, &PostReview.turned_away/0)
      |> assign_new(:latest, &ModerationQueue.latest/0)
      |> assign_new(:decisions, &ModerationQueue.decisions/0)

    {:ok, socket, layout: false}
  end

  # Hold, Put back and Remove, with the reason typed beside them.
  @impl true
  def handle_event(
        "moderate",
        %{"subject" => %{"kind" => kind, "id" => id, "action" => action} = subject},
        socket
      )
      when is_binary(kind) and is_binary(id) do
    with {:ok, action} <- moderation_action(action),
         {:ok, record} <- fetch_subject(kind, id) do
      moderate(record, action, reason(subject["reason"]), socket.assigns.current_profile)
    end
    |> answered(socket, "#{kind}-#{id}")
  end

  # A ruling on a post turned away, its use as an example, or a lifted pause.
  def handle_event("review", %{"kind" => "post", "id" => id, "action" => action}, socket)
      when is_binary(id) do
    moderator = socket.assigns.current_profile

    case action do
      "right" -> PostReview.rule(id, :right, moderator)
      "wrong" -> PostReview.rule(id, :wrong, moderator)
      "none" -> PostReview.rule(id, :none, moderator)
      "example" -> PostReview.use_as_example(id, moderator)
      "no_example" -> PostReview.drop_example(id, moderator)
      _other -> {:error, @not_a_decision}
    end
    |> answered(socket, "post-#{id}")
  end

  def handle_event("review", %{"kind" => "person", "id" => id, "action" => "lift"}, socket)
      when is_binary(id) do
    id
    |> PostReview.lift_pause(socket.assigns.current_profile)
    |> answered(socket, "person-#{id}")
  end

  # A press that names no row has nowhere to be answered.
  def handle_event(event, _params, socket) when event in ~w(moderate review),
    do: {:noreply, socket}

  defp answered({:ok, _done}, socket, _row),
    do: {:noreply, socket |> assign(ModerationQueue.read()) |> assign(refused: %{})}

  defp answered({:error, words}, socket, row),
    do: {:noreply, assign(socket, refused: %{row => words})}

  defp moderation_action("quarantine"), do: {:ok, :quarantine}
  defp moderation_action("publish"), do: {:ok, :publish}
  defp moderation_action("redact"), do: {:ok, :redact}
  defp moderation_action(_other), do: {:error, @not_a_decision}

  defp fetch_subject("thread", id), do: fetch(Report, id)
  defp fetch_subject("reply", id), do: fetch(Reply, id)
  defp fetch_subject(_kind, _id), do: {:error, "That is not something moderation touches."}

  # Moderation reads records regardless of visibility — that is the point of
  # the page — through reads only this door makes. The allowlist check is the
  # door's; these reads skip policy because their subjects are deny-all.
  defp fetch(resource, id) do
    case resource
         |> Ash.Query.filter(id == ^id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, "That record does not exist."}
      {:ok, record} -> {:ok, record}
      {:error, _failure} -> {:error, "That record could not be read."}
    end
  end

  # The decision itself is the action's, under its own policy, as the moderator.
  defp moderate(record, action, reason, moderator) do
    case Forum.moderate(record, action, reason, moderator) do
      {:ok, updated} -> {:ok, updated}
      {:error, _failure} -> {:error, "That decision was not saved. Try again."}
    end
  end

  defp reason(text) when is_binary(text), do: String.slice(String.trim(text), 0, 500)
  defp reason(_other), do: "No reason given."

  # A held record's row, named as its decision names it.
  defp row(kind, record), do: "#{subject_label(kind)}-#{record.id}"
end
