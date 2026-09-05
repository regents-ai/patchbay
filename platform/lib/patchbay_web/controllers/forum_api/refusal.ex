defmodule PatchbayWeb.ForumAPI.Refusal do
  @moduledoc """
  The words a forum endpoint refuses with, one line per rule the caller broke.

  Every endpoint that files or freezes a report answers with the same words for
  the same mistake, so an agent that has read one refusal has read them all.
  A public endpoint answers with the contract the caller broke, never with
  anything about how the forum is built: a refusal names the field the caller
  sent, not the field the forum stores, and an error with no field of its own
  is reported plainly rather than rendered.
  """

  @generic_failure "That could not be posted. Check the values you sent and try again."

  @public_field_names %{name: "tool_name", title: "tool_title", description: "tool_description"}

  @doc "One line for each distinct reason a write was refused."
  @spec messages(term()) :: [String.t()]
  def messages(error) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.map(&describe/1)
    |> Enum.uniq()
    |> case do
      [] -> [@generic_failure]
      described -> described
    end
  end

  @doc "One refusal as a line naming the field the caller sent."
  @spec describe(Exception.t()) :: String.t()
  def describe(error) do
    case field_of(error) do
      nil -> @generic_failure
      field -> "#{public_name(field)}: #{field_message(field, error)}"
    end
  end

  @doc "The words for a refusal that names no field."
  @spec generic_failure() :: String.t()
  def generic_failure, do: @generic_failure

  @doc "The field an error is about, if it is about one."
  @spec field_of(Exception.t()) :: atom() | nil
  def field_of(error) do
    case {Map.get(error, :field), Map.get(error, :fields)} do
      {field, _fields} when is_atom(field) and not is_nil(field) -> field
      {_field, [field | _rest]} when is_atom(field) -> field
      _ -> nil
    end
  end

  defp public_name(field), do: Map.get(@public_field_names, field, to_string(field))

  # These four fields carry a pattern the forum would otherwise report as the
  # pattern itself, which is not something a caller can read. Each replacement
  # states the whole rule, so it is true whether the value was missing or wrong.
  @doc "The rule an error says a field broke, in words a caller can act on."
  @spec field_message(atom(), Exception.t()) :: String.t()
  def field_message(:verdict, _error) do
    "must be one of verified_success, verified_failure, errored, unknown"
  end

  def field_message(field, _error) when field in [:arguments_sha256, :contract_sha256] do
    "must be a 64-character lowercase hex digest"
  end

  def field_message(:name, _error) do
    "must start with a lowercase letter and hold only lowercase letters, digits and underscores, up to 64 characters"
  end

  def field_message(_field, error) do
    error
    |> Map.get(:message)
    |> case do
      message when is_binary(message) -> message
      _ -> Exception.message(error)
    end
    |> substitute(Map.get(error, :vars) || [])
  end

  defp substitute(message, vars) do
    Enum.reduce(vars, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
