defmodule Patchbay.Forum.Validations.BoundedMap do
  @moduledoc """
  Caps how much evidence a single report may carry.

  Size is measured over the canonical JSON encoding rather than the in-memory
  term so the limit means the same thing for every client that sends the same
  payload.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias Patchbay.Patchbay.CanonicalJSON

  @impl true
  def init(opts) do
    with [_ | _] = attributes <- opts[:attributes],
         max_bytes when is_integer(max_bytes) and max_bytes > 0 <- opts[:max_bytes] do
      {:ok, attributes: attributes, max_bytes: max_bytes}
    else
      _ -> {:error, "`:attributes` and a positive `:max_bytes` are required"}
    end
  end

  @impl true
  def validate(changeset, opts, _context) do
    Enum.reduce_while(opts[:attributes], :ok, fn attribute, :ok ->
      case Ash.Changeset.get_attribute(changeset, attribute) do
        value when is_map(value) ->
          check_size(attribute, value, opts[:max_bytes])

        _ ->
          {:cont, :ok}
      end
    end)
  end

  @impl true
  def describe(opts) do
    [message: "must encode to at most %{max_bytes} bytes", vars: [max_bytes: opts[:max_bytes]]]
  end

  defp check_size(attribute, value, max_bytes) do
    encoded = CanonicalJSON.encode(value)

    if byte_size(encoded) <= max_bytes do
      {:cont, :ok}
    else
      {:halt, {:error, error(attribute, "must encode to at most #{max_bytes} bytes")}}
    end
  rescue
    _ in [ArgumentError, Protocol.UndefinedError] ->
      {:halt, {:error, error(attribute, "must contain only JSON values")}}
  end

  defp error(attribute, message),
    do: InvalidAttribute.exception(field: attribute, message: message)
end
