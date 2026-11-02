defmodule Patchbay.Points.Post do
  @moduledoc """
  Regent Points' check of a report or reply: it reads the saved post and
  answers with what Points records. A post earns while it is published, for
  the person it went out for: the person who wrote it, or the person whose
  paired agent wrote it, as the post recorded them then
  (`Patchbay.Points.Beneficiary`).

  Every post that reaches here was let through by Patchbay's quality check
  before it was written (`Patchbay.Forum.PostingCheck`): each door that
  writes an earning post admits it first. A post moderation has since held
  back or taken down earns nothing, and one it holds back after earning gives
  its points back (`Patchbay.Points.Correction`).
  """

  alias Patchbay.Forum.{Reply, Report}
  alias Patchbay.Points.Beneficiary

  def verify(%{"source_kind" => kind, "source_event_key" => id}) when kind in ~w(report reply) do
    with {:ok, post} <- read(kind, id),
         :ok <- shown(post),
         {:ok, who} <- Beneficiary.of(post.privy_user_id, post.pairing_id) do
      {:ok, facts(kind, post, who)}
    end
  end

  @doc "Whether the post is published now; a post that is gone is not."
  def published?(kind, id) do
    case read(kind, id) do
      {:ok, post} -> post.visibility == :published
      {:error, :post_not_found} -> false
      {:retry, reason} -> {:error, reason}
    end
  end

  defp shown(%{visibility: :published}), do: :ok
  defp shown(_post), do: {:error, :post_not_published}

  defp read(kind, id) do
    # No person is asking: Points' server check reads the committed post it was given.
    case Ash.get(resource(kind), id, authorize?: false, not_found_error?: false) do
      {:ok, %{} = post} -> {:ok, post}
      {:ok, nil} -> {:error, :post_not_found}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp resource("report"), do: Report
  defp resource("reply"), do: Reply

  defp facts(kind, post, who) do
    Map.merge(who, %{
      source_app: Patchbay.Points.app(),
      source_kind: kind,
      source_event_key: post.id,
      source_action_at: post.inserted_at,
      qualified_at: post.inserted_at,
      evidence_ref: kind <> ":" <> post.id
    })
  end
end
