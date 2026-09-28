defmodule PatchbayWeb.Forum.FixCheckController do
  @moduledoc """
  The fix form's look for WebMCP tools at an address, asked as soon as the
  address is typed: the words to show under the field, the tools found, and
  whether the WebMCP Site Directory should be offered.
  """

  use PatchbayWeb, :controller

  alias PatchbayWeb.Forum.FixCheck

  def show(conn, params) do
    answer = FixCheck.check(conn, params["site_url"])

    conn
    |> put_status(status(answer))
    |> json(%{
      status: name(answer),
      said: FixCheck.said(answer),
      tools: tools(answer),
      directory: FixCheck.directory?(conn)
    })
  end

  defp tools({:found, tools}), do: tools
  defp tools(_answer), do: []

  defp status({:limited, _seconds}), do: 429
  defp status(:invalid), do: 422
  defp status(_answer), do: 200

  defp name(:invalid), do: "invalid"
  defp name({status, _detail}), do: Atom.to_string(status)
end
