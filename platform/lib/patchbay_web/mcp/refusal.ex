defmodule PatchbayWeb.MCP.Refusal do
  @moduledoc """
  How the two hosted MCP addresses, `/mcp` and `/chatgpt/mcp`, answer a
  request they turn away before any tool runs: unsigned, not paired, the
  person not here, the sign-in service down, or past a rate limit.

  The answer is JSON-RPC, with the request's own id, so an MCP client can
  match it to the call and show the model what to do rather than a broken
  connection. A refused `tools/call` is a tool result with `isError: true`;
  any other method, and a notification, gets a JSON-RPC error whose `data` is
  the same refusal.
  Either way the refusal is the `{code, message, hint}` every Patchbay door
  answers with (`PatchbayWeb.ApiError`). Both are sent with status 200: the
  request reached the server and was answered; the refusal is in the body. A
  notification, which has no id and asks for no answer, is refused with the
  refusal's own HTTP status instead.

  A rate limit carries `retry_after_seconds` beside its code, as well as the
  `Retry-After` and RateLimit headers, and its words say to wait. Nothing
  about it reads as pairing.
  """

  import Plug.Conn

  alias PatchbayWeb.ApiError

  @doc """
  Answers the request on `conn` with `error`, the refusal's `error` object,
  and halts. `status` is the refusal's HTTP status, sent only when the
  request is a notification.
  """
  @spec refuse(Plug.Conn.t(), map(), pos_integer()) :: Plug.Conn.t()
  def refuse(conn, error, status) do
    request = request(conn)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      if(Map.has_key?(request, "id"), do: 200, else: status),
      Jason.encode!(answer(conn, request, error))
    )
    |> halt()
  end

  @doc "A rate-limit refusal, for a share that has room again in `seconds`."
  @spec rate_limited(Plug.Conn.t(), pos_integer()) :: Plug.Conn.t()
  def rate_limited(conn, seconds) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> refuse(
      ApiError.body(
        "rate_limited",
        "Too many requests from this address. Wait #{seconds} #{unit(seconds)}, then send it again.",
        "Wait the #{seconds} #{unit(seconds)} in retry_after_seconds, then send the same request again. Nothing else needs to change.",
        %{retry_after_seconds: seconds}
      ).error,
      429
    )
  end

  @doc """
  A refusal as a tool result: `isError`, and the refusal's JSON, the same
  `{"error": {code, message, hint, ...}}` every door answers with, as its one
  text block. It carries no structured content, which a client would check
  against the tool's `outputSchema` and so never show.
  """
  @spec tool_result(%{error: map()}) :: map()
  def tool_result(%{error: %{}} = refusal) do
    %{
      "content" => [%{"type" => "text", "text" => Jason.encode!(refusal)}],
      "isError" => true
    }
  end

  @doc "The code of a refusal `tool_result/1` made."
  @spec code(map()) :: String.t()
  def code(%{"content" => [%{"text" => text}]}),
    do: text |> Jason.decode!() |> get_in(["error", "code"])

  @doc """
  True for a request in MCP 2.0 (2026-07-28), named in the request's own
  metadata or in the `MCP-Protocol-Version` header; its results carry
  `resultType`.
  """
  @spec modern?(Plug.Conn.t(), map()) :: boolean()
  def modern?(_conn, %{
        "params" => %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}}
      }),
      do: true

  def modern?(conn, _request), do: get_req_header(conn, "mcp-protocol-version") == ["2026-07-28"]

  @doc "The request's id when it is one JSON-RPC allows, else nil."
  @spec id(map()) :: String.t() | integer() | nil
  def id(%{"id" => id}) when is_binary(id) or is_integer(id), do: id
  def id(_request), do: nil

  defp answer(conn, %{"method" => "tools/call", "id" => _} = request, error) do
    result = tool_result(%{error: error})

    result =
      if modern?(conn, request), do: Map.put(result, "resultType", "complete"), else: result

    %{jsonrpc: "2.0", id: id(request), result: result}
  end

  defp answer(_conn, request, error),
    do: %{
      jsonrpc: "2.0",
      id: id(request),
      error: %{code: -32_000, message: error.message, data: error}
    }

  # The parsed body: one JSON object is the request; anything else has no id.
  defp request(%{body_params: %Plug.Conn.Unfetched{}}), do: %{}
  defp request(%{body_params: %{} = params}), do: params
  defp request(_conn), do: %{}

  defp unit(1), do: "second"
  defp unit(_seconds), do: "seconds"
end
