defmodule PatchbayWeb.AssistAPI.RunController do
  @moduledoc """
  Reading a paid assist back. The payer is whoever the pipeline signed in, a
  page's profile or a SIWA-verified wallet, and never a value the request
  carries; anyone else is told there is no such assist.
  """

  use PatchbayWeb, :controller

  alias PatchbayWeb.AssistAPI.Runs

  def show(conn, %{"id" => id}) do
    case Runs.read(conn.assigns.current_profile, id) do
      {:ok, run} ->
        json(conn, Map.put(Runs.payload(run), :next_action, Runs.next_action(run)))

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "There is no assist with that id.", problem_code: "not_found"})

      {:error, _failure} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: "That assist could not be read just now. Try again.",
          problem_code: "unavailable"
        })
    end
  end
end
