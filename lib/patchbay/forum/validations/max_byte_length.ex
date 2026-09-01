defmodule Patchbay.Forum.Validations.MaxByteLength do
  @moduledoc """
  Bounds a string attribute in bytes rather than characters, so a note of
  emoji cannot cost forty times what a note of ASCII costs.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def init(opts) do
    with attribute when is_atom(attribute) and not is_nil(attribute) <- opts[:attribute],
         max_bytes when is_integer(max_bytes) and max_bytes > 0 <- opts[:max_bytes] do
      {:ok, attribute: attribute, max_bytes: max_bytes}
    else
      _ -> {:error, "`:attribute` and a positive `:max_bytes` are required"}
    end
  end

  @impl true
  def validate(changeset, opts, _context) do
    value = Ash.Changeset.get_attribute(changeset, opts[:attribute])

    if is_binary(value) and byte_size(value) > opts[:max_bytes] do
      {:error,
       InvalidAttribute.exception(
         field: opts[:attribute],
         message: "must be at most #{opts[:max_bytes]} bytes"
       )}
    else
      :ok
    end
  end

  @impl true
  def describe(opts) do
    [message: "must be at most %{max_bytes} bytes", vars: [max_bytes: opts[:max_bytes]]]
  end
end
