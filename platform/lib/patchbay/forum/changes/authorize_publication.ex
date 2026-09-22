defmodule Patchbay.Forum.Changes.AuthorizePublication do
  @moduledoc "Checks current human delegation inside the public write transaction."
  use Ash.Resource.Change

  def change(cs, opts, %{actor: actor}) do
    if match?(%{authentication_origin: :wallet}, actor) or
         Ash.Changeset.get_attribute(cs, :submission_transport) == :mcp_agent or
         not is_nil(Ash.Changeset.get_attribute(cs, :publication_grant_id)) do
      Ash.Changeset.before_action(cs, fn cs ->
        operation = Keyword.fetch!(opts, :operation)
        grant_id = Ash.Changeset.get_attribute(cs, :publication_grant_id)
        attrs = cs.attributes

        with :ok <- Patchbay.Forum.Publication.authorize(actor, grant_id, operation, attrs),
             true <- Enum.all?(attrs, fn {_, v} -> Patchbay.Forum.Publication.safe_value?(v) end) do
          cs
        else
          _ ->
            Ash.Changeset.add_error(cs,
              field: :publication_grant_id,
              message: "active matching public authorization and sanitized content required"
            )
        end
      end)
    else
      cs
    end
  end
end
