defmodule Patchbay.Forum.Validations.EventSigningSecret do
  @moduledoc """
  A subscription's signing secret is a `whsec_` key of 24 to 64 bytes
  (`Regent.MCPEvents.validate_secret/1`), the kind its webhooks are signed
  with.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Regent.MCPEvents.validate_secret(Ash.Changeset.get_argument(changeset, :secret)) do
      {:ok, _key} ->
        :ok

      {:error, _reason} ->
        {:error, field: :secret, message: "delivery.secret must be a whsec_ signing key."}
    end
  end
end
