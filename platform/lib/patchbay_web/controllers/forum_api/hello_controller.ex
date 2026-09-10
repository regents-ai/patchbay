defmodule PatchbayWeb.ForumAPI.HelloController do
  use PatchbayWeb, :controller
  alias Patchbay.Forum.Hellos

  def index(conn, params) do
    case Hellos.latest(params["stream"]) do
      {:ok, events} -> json(conn, %{events: Enum.map(events, &Hellos.public/1)})
      {:error, _} -> unavailable(conn)
    end
  end

  def create(conn, params) do
    with :ok <- valid_input(params),
         {:ok, principal} <- principal(conn),
         {:ok, event} <-
           Hellos.record(params["name"], params["language"] || browser_language(conn), principal) do
      conn |> put_status(:created) |> json(%{recorded: true, event: Hellos.public(event)})
    else
      {:error, :invalid} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          recorded: false,
          error: "Supply a self-chosen name as text and an optional language tag."
        })

      {:error, :no_session} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{
          recorded: false,
          error: "Open /start first and keep its session and CSRF token."
        })

      {:error, :rate_limited} ->
        conn
        |> put_status(:too_many_requests)
        |> put_resp_header("retry-after", "3600")
        |> json(%{
          recorded: false,
          error: "This session or wallet has sent 30 hellos in the past hour. Try later."
        })

      {:error, _} ->
        unavailable(conn)
    end
  end

  defp valid_input(%{"name" => name} = params) when is_binary(name) do
    if Map.keys(params) -- ["name", "language"] == [] and
         (is_nil(params["language"]) or is_binary(params["language"])),
       do: :ok,
       else: {:error, :invalid}
  end

  defp valid_input(_), do: {:error, :invalid}

  defp principal(%{assigns: %{hello_wallet: address}}), do: {:ok, {:siwa, address}}

  defp principal(%{assigns: %{forum_session_id: id}}) when is_binary(id),
    do: {:ok, {:browser, id}}

  defp principal(_), do: {:error, :no_session}

  defp browser_language(conn), do: get_req_header(conn, "accept-language") |> List.first()

  defp unavailable(conn),
    do:
      conn
      |> put_status(:service_unavailable)
      |> json(%{
        recorded: false,
        error: "Hello stream unavailable. Check the stream before retrying a write."
      })
end
