defmodule Patchbay.Forum.Changes.ValidateMachineContext do
  @moduledoc "Binds machine context and outcome corrections to their active wallet author."
  use Ash.Resource.Change
  require Ash.Query

  @fields [
    :operation_id,
    :operation_name,
    :submission_transport,
    :target_interface,
    :agent_environment
  ]
  @context_fields @fields -- [:operation_id]

  def change(changeset, _opts, %{actor: actor}) do
    if changeset.resource == Patchbay.Forum.AnswerUse do
      Ash.Changeset.before_action(changeset, &validate_answer_use(&1, actor))
    else
      validate_context(changeset, actor)
    end
  end

  defp machine?(changeset),
    do:
      Enum.any?(@fields, &Ash.Changeset.get_attribute(changeset, &1)) ||
        Ash.Changeset.get_attribute(changeset, :machine_principal)

  defp validate_context(changeset, actor, required? \\ false) do
    if required? || machine?(changeset) do
      wallet? = match?(%{authentication_origin: :wallet, status: :active}, actor)
      principal = if wallet?, do: Patchbay.Forum.Principal.for_profile(actor.id)

      stored_principal =
        Ash.Changeset.get_attribute(changeset, :machine_principal) ||
          Ash.Changeset.get_attribute(changeset, :principal)

      if wallet? and stored_principal == principal and
           Enum.all?(@fields, &Ash.Changeset.get_attribute(changeset, &1)) and
           is_nil(Ash.Changeset.get_attribute(changeset, :browser_session_id)) do
        changeset
      else
        Ash.Changeset.add_error(changeset,
          field: :operation_id,
          message: "requires the matching wallet author and complete machine context"
        )
      end
    else
      changeset
    end
  end

  defp validate_answer_use(changeset, actor) do
    reply_id = Ash.Changeset.get_attribute(changeset, :reply_id)
    principal = Ash.Changeset.get_attribute(changeset, :principal)
    task_token = Ash.Changeset.get_attribute(changeset, :task_token)

    Patchbay.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
      "answer-use:" <> principal <> ":" <> reply_id <> ":" <> task_token
    ])

    existing =
      Patchbay.Forum.AnswerUse
      |> Ash.Query.filter(
        reply_id == ^reply_id and principal == ^principal and task_token == ^task_token
      )
      |> Ash.read_one!()

    required? = !!(machine?(changeset) || (existing && existing.submission_transport != nil))
    changeset = validate_context(changeset, actor, required?)

    if required? and changeset.valid? do
      with {:ok, %{visibility: :published, report: %{visibility: :published}}} <-
             Ash.get(Patchbay.Forum.Reply, reply_id, load: [:report]) do
        if existing &&
             Enum.any?(
               @context_fields,
               &(Map.get(existing, &1) != Ash.Changeset.get_attribute(changeset, &1))
             ) do
          Ash.Changeset.add_error(changeset,
            field: :task_token,
            message: "already identifies a different context"
          )
        else
          changeset
        end
      else
        _ ->
          Ash.Changeset.add_error(changeset,
            field: :reply_id,
            message: "must belong to a published answer thread"
          )
      end
    else
      changeset
    end
  end
end
