defmodule PatchbayWeb.ForumAPI.ToolController do
  use PatchbayWeb, :controller

  alias PatchbayWeb.ApiError
  alias PatchbayWeb.ForumAPI.Reads

  def index(conn, params) do
    case Reads.tool_history(params) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, {status, code, message, hint}} ->
        conn |> put_status(status) |> json(ApiError.body(code, message, hint))
    end
  end
end
