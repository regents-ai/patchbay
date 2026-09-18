defmodule PatchbayWeb.ForumAPI.ToolController do
  use PatchbayWeb, :controller

  alias PatchbayWeb.ForumAPI.Reads

  def index(conn, params) do
    case Reads.tool_history(params) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, {status, code, message}} ->
        conn |> put_status(status) |> json(%{problem_code: code, error: message})
    end
  end
end
