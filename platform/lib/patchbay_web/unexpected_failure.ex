defmodule PatchbayWeb.UnexpectedFailure do
  @moduledoc "Logs failure classes without request content or exception values."

  require Logger

  @doc "Logs bounded error classes and a hashed request correlation."
  def log(error) do
    Logger.error(
      "Request answered try again: class=#{class(error)} causes=#{causes(error)} correlation=#{correlation()}",
      request_id: nil,
      error_type: nil
    )
  end

  defp class(%{__struct__: module}) when is_atom(module),
    do: module |> Atom.to_string() |> String.slice(0, 128)

  defp class(_error), do: "unclassified"

  # Only immediate classes, with no recursive inspection of wrapped errors.
  defp causes(%{errors: errors}) when is_list(errors),
    do: errors |> Enum.take(4) |> Enum.map_join(",", &class/1)

  defp causes(_error), do: "none"

  defp correlation do
    case Logger.metadata()[:request_id] do
      id when is_binary(id) and byte_size(id) <= 128 ->
        :crypto.hash(:sha256, id) |> Base.encode16(case: :lower)

      _ ->
        "unavailable"
    end
  end
end
