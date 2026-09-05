defmodule Patchbay.Identity.Validations.NameIsFree do
  @moduledoc """
  Refuses a name another profile already holds, in either of its halves.

  A profile's two names are two columns, so the database can promise on its own
  that no two profiles share a human name and that no two share an agent name.
  What it cannot promise across two columns is that one profile's agent is not
  called what another profile's person is called, and a reader who has to ask
  which of two identical names they are looking at is exactly what names are
  for. So the other half is read here.

  Two profiles claiming the same name in the same instant could still both pass
  this read; the database refuses the duplicate within a half, and a name is
  never how money finds a profile, which is addressed by its public id.
  """

  use Ash.Resource.Validation

  require Ash.Query

  alias Ash.Error.Changes.InvalidAttribute
  alias Patchbay.Identity.AgentProfile

  @impl true
  def init(opts) do
    case opts[:attribute] do
      attribute when attribute in [:human_name, :agent_name] -> {:ok, opts}
      other -> {:error, "attribute must be :human_name or :agent_name, got: #{inspect(other)}"}
    end
  end

  @impl true
  def validate(changeset, opts, _context) do
    attribute = opts[:attribute]

    case Ash.Changeset.get_attribute(changeset, attribute) do
      nil -> :ok
      name -> free(changeset.data.id, attribute, name)
    end
  end

  @impl true
  def describe(_opts) do
    [message: "is already taken", vars: []]
  end

  @spec free(Ash.UUID.t(), atom(), String.t()) :: :ok | {:error, Exception.t()}
  defp free(profile_id, attribute, name) do
    # Whether a name is free is not this writer's business to be allowed to
    # see: the read exists only to answer their own write, and it hands back
    # nothing but yes or no.
    taken? =
      AgentProfile
      |> Ash.Query.for_read(:read, %{}, authorize?: false)
      |> Ash.Query.filter(id != ^profile_id and (human_name == ^name or agent_name == ^name))
      |> Ash.exists?(authorize?: false)

    if taken? do
      {:error,
       InvalidAttribute.exception(
         field: attribute,
         message: "is already taken by somebody else on Patchbay"
       )}
    else
      :ok
    end
  end
end
