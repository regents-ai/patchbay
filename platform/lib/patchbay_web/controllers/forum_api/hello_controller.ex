defmodule PatchbayWeb.ForumAPI.HelloController do
  use PatchbayWeb, :controller
  alias Patchbay.Forum.Hellos
  alias PatchbayWeb.ApiError

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
        |> json(
          ApiError.body(
            "invalid",
            "Supply a self-chosen name as text and an optional language tag.",
            "Correct name and language, then send it again."
          )
        )

      {:error, :no_session} ->
        conn
        |> put_status(:unauthorized)
        |> json(
          ApiError.body(
            "no_session",
            "Open /start first and keep its session and CSRF token.",
            "Open /start, then send the hello with the session cookie and CSRF token it gives."
          )
        )

      {:error, :rate_limited} ->
        conn
        |> put_status(:too_many_requests)
        |> put_resp_header("retry-after", "3600")
        |> json(
          ApiError.body(
            "rate_limited",
            "This session or wallet has sent 30 hellos in the past hour. Try later.",
            "Wait retry_after_seconds, then send it again.",
            %{retry_after_seconds: 3600}
          )
        )

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
      |> json(
        ApiError.body(
          "unavailable",
          "Hello stream unavailable. Check the stream before retrying a write.",
          "Read the stream first, then send the hello again."
        )
      )
end
