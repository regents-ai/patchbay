defmodule PatchbayWeb.ForumAPI.ToolController do
  use PatchbayWeb, :controller
  alias Patchbay.Forum
  alias Patchbay.Forum.Origin
  alias PatchbayWeb.Forum.ToolHistory

  def index(conn, params) do
    with true <- Enum.all?(Map.keys(params), &(&1 in ~w(origin tool_name after limit))),
         {:ok, origin} <- Origin.normalize(params["origin"]),
         true <- PatchbayWeb.Forum.Board.tool_name?(params["tool_name"]),
         {:ok, limit} <- limit(params["limit"]),
         {:ok, site} <- Forum.get_site_by_origin(origin, not_found_error?: false),
         false <- is_nil(site),
         {:ok, history} <- ToolHistory.page(site, params["tool_name"], params["after"], limit) do
      if history.versions == [] and is_nil(params["after"]) do
        failure(conn, 404, "not_found", "Tool not found.")
      else
        json(conn, %{
          origin: site.origin,
          tool_name: params["tool_name"],
          versions: Enum.map(history.versions, &public_version/1),
          pagination: history.pagination
        })
      end
    else
      true ->
        failure(conn, 404, "not_found", "Site not found.")

      false ->
        failure(
          conn,
          400,
          "invalid_request",
          "Use an origin, tool_name and optional limit from 1 to 25."
        )

      {:error, :invalid_cursor} ->
        failure(
          conn,
          400,
          "invalid_cursor",
          "This cursor is invalid or expired. Restart the same tool history."
        )

      {:error, :invalid_limit} ->
        failure(conn, 400, "invalid_request", "Use a limit from 1 to 25.")

      {:error, reason} when is_binary(reason) ->
        failure(conn, 400, "invalid_request", "Use a public site origin.")

      {:error, _} ->
        failure(conn, 503, "unavailable", "Tool history is unavailable. Retry the same query.")
    end
  end

  defp limit(nil), do: {:ok, 25}

  defp limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n in 1..25 -> {:ok, n}
      _ -> {:error, :invalid_limit}
    end
  end

  defp limit(_), do: {:error, :invalid_limit}

  defp public_version(tool) do
    tool
    |> Map.take([
      :id,
      :name,
      :contract_sha256,
      :title,
      :description,
      :stable_key,
      :published_name,
      :display_name,
      :protocol_version,
      :input_schema,
      :output_schema,
      :raw_definition,
      :source_kind,
      :source_url,
      :status,
      :first_seen_at,
      :last_seen_at
    ])
  end

  defp failure(conn, status, code, message),
    do: conn |> put_status(status) |> json(%{problem_code: code, error: message})
end
