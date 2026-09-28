defmodule PatchbayWeb.AssistAPI.RunController do
  @moduledoc """
  Reading a paid assist back. The payer is whoever the pipeline signed in, a
  page's profile or a SIWA-verified wallet, and never a value the request
  carries; anyone else is told there is no such assist.
  """

  use PatchbayWeb, :controller

  alias PatchbayWeb.ApiError
  alias PatchbayWeb.AssistAPI.Runs

  def show(conn, %{"id" => id}) do
    case Runs.read(conn.assigns.current_profile, id) do
      {:ok, run} ->
        json(conn, Map.put(Runs.payload(run), :next_action, Runs.next_action(run)))

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(
          ApiError.body(
            "not_found",
            "There is no assist with that id.",
            "Check the run_id from the answer that opened the assist."
          )
        )

      {:error, _failure} ->
        conn
        |> put_status(:internal_server_error)
        |> json(
          ApiError.body(
            "unavailable",
            "That assist could not be read just now. Try again.",
            "Try the same call again in a moment."
          )
        )
    end
  end
end
