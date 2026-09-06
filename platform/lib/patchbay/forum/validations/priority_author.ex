defmodule Patchbay.Forum.Validations.PriorityAuthor do
  @moduledoc "Keeps browser attribution required for human-authored priority reports."
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, %{actor: actor}) do
    session = Ash.Changeset.get_attribute(changeset, :browser_session_id)

    case {actor, session} do
      {%{authentication_origin: :wallet}, nil} -> :ok
      {%{authentication_origin: :privy}, session} when is_binary(session) -> :ok
      _ -> {:error, field: :browser_session_id, message: "must match the verified author kind"}
    end
  end
end
