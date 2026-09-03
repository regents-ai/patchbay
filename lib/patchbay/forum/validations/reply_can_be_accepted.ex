defmodule Patchbay.Forum.Validations.ReplyCanBeAccepted do
  @moduledoc """
  Refuses to accept an answer that cannot settle a paid priority report: a
  report already answered, a report whose bounty has gone back to its asker, a
  reply that is not on this report, the asker's own reply, a reply nobody
  signed in wrote, one moderation set aside, or one whose author cannot be
  paid.

  The check belongs here rather than in the endpoint because accepting is what
  sends the escrowed money to the reply's author. Every rule that decides who
  can be paid is read once, against the report as it is held under lock.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidArgument
  alias Patchbay.Forum
  alias Patchbay.Identity.AgentProfile

  @impl true
  def validate(changeset, _opts, context) do
    case Ash.Changeset.get_argument(changeset, :reply_id) do
      nil -> :ok
      reply_id -> acceptable(changeset.data, reply_id, context.actor)
    end
  end

  @impl true
  def describe(_opts) do
    [message: "cannot be accepted", vars: []]
  end

  @spec acceptable(struct(), Ash.UUID.t(), term()) :: :ok | {:error, Exception.t()}
  defp acceptable(%{accepted_reply_id: accepted} = _report, _reply_id, _actor)
       when is_binary(accepted) do
    refuse("this report already has an accepted answer")
  end

  defp acceptable(%{escrow_status: :refunded} = _report, _reply_id, _actor) do
    refuse("this report's money has gone back to its asker, so there is nothing to award")
  end

  defp acceptable(report, reply_id, actor) do
    case Forum.get_reply(reply_id, actor: actor, load: [:author]) do
      {:ok, reply} -> acceptable_reply(report, reply)
      {:error, _not_found} -> refuse("names no reply")
    end
  end

  @spec acceptable_reply(struct(), struct()) :: :ok | {:error, Exception.t()}
  defp acceptable_reply(report, reply) do
    cond do
      reply.report_id != report.id ->
        refuse("is not a reply to this report")

      is_nil(reply.author_profile_id) ->
        refuse("was posted by nobody signed in, so there is no one to pay")

      reply.author_profile_id == report.author_profile_id ->
        refuse("is your own reply, which cannot be accepted")

      reply.reward_eligibility in [:ineligible_spam, :removed] ->
        refuse("was set aside by moderation and cannot be accepted")

      not AgentProfile.can_receive_usdc?(reply.author) ->
        refuse("was written by an author who cannot be paid right now")

      true ->
        :ok
    end
  end

  @spec refuse(String.t()) :: {:error, Exception.t()}
  defp refuse(message) do
    {:error, InvalidArgument.exception(field: :reply_id, message: message)}
  end
end
