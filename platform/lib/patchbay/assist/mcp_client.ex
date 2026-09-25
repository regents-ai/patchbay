defmodule Patchbay.Assist.McpClient do
  @moduledoc """
  A small client for a site's own MCP server over HTTP: enough to open a
  session, read the tools it offers and call one.

  Every message is one JSON-RPC request answered with one JSON body, or with
  an event stream whose first message is the answer, which is all the
  protocol's HTTP form asks of a client. What the server sends back is a
  stranger's text: it is bounded, read for its shape and nothing more, and
  handed on as data.
  """

  alias Patchbay.Assist.Target

  @protocol_version "2025-06-18"
  @call_timeout_ms 20_000
  @list_pages 5
  @max_tools 200
  @max_schema_bytes 8_192

  @type client :: %{target: Target.target(), session: String.t() | nil}
  @type tool :: %{
          name: String.t(),
          description: String.t(),
          input_schema: map() | nil,
          read_only?: boolean()
        }

  @doc """
  Opens a session with the server at the target, if there is one there:
  `{:error, :not_mcp}` when what answers is not an MCP server.
  """
  @spec open(Target.target()) :: {:ok, client()} | {:error, :not_mcp | term()}
  def open(target) do
    client = %{target: target, session: nil}

    params = %{
      protocolVersion: @protocol_version,
      capabilities: %{},
      clientInfo: %{
        name: "patchbay-assist",
        version: to_string(Application.spec(:patchbay, :vsn))
      }
    }

    case request(client, "initialize", params) do
      {:ok, %{"protocolVersion" => _}, session} ->
        opened = %{client | session: session}
        _ = notify(opened, "notifications/initialized")
        {:ok, opened}

      {:ok, _not_an_initialize_answer, _session} ->
        {:error, :not_mcp}

      {:error, {:status, _status}} ->
        {:error, :not_mcp}

      {:error, :not_json_rpc} ->
        {:error, :not_mcp}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The tools the server offers, at most #{@max_tools}, read page by page."
  @spec list_tools(client()) :: {:ok, [tool()]} | {:error, term()}
  def list_tools(client), do: list_tools(client, nil, [], @list_pages)

  defp list_tools(_client, _cursor, tools, 0), do: {:ok, Enum.take(tools, @max_tools)}

  defp list_tools(client, cursor, tools, pages_left) do
    params = if cursor, do: %{cursor: cursor}, else: %{}

    case request(client, "tools/list", params) do
      {:ok, %{"tools" => listed} = result, _session} when is_list(listed) ->
        tools = tools ++ Enum.flat_map(listed, &shaped_tool/1)

        case result["nextCursor"] do
          next when is_binary(next) and length(tools) < @max_tools ->
            list_tools(client, next, tools, pages_left - 1)

          _last_page ->
            {:ok, Enum.take(tools, @max_tools)}
        end

      {:ok, _other, _session} ->
        {:error, :unexpected_answer}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Calls one tool. The answer is the text the server put in the result,
  whether it marked it an error, and its structured content if any.
  """
  @spec call_tool(client(), String.t(), map()) ::
          {:ok, %{text: String.t(), error?: boolean()}} | {:error, term()}
  def call_tool(client, name, arguments) do
    case request(client, "tools/call", %{name: name, arguments: arguments}) do
      {:ok, %{"content" => content} = result, _session} when is_list(content) ->
        {:ok, %{text: text(content, result), error?: result["isError"] == true}}

      {:ok, %{"structuredContent" => structured}, _session} when is_map(structured) ->
        {:ok, %{text: Jason.encode!(structured), error?: false}}

      {:ok, _other, _session} ->
        {:error, :unexpected_answer}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp text(content, result) do
    texts =
      for %{"type" => "text", "text" => text} when is_binary(text) <- content, do: text

    case {texts, result["structuredContent"]} do
      {[], structured} when is_map(structured) -> Jason.encode!(structured)
      {texts, _} -> Enum.join(texts, "\n")
    end
  end

  # A tool as the run keeps it: name and description cut to size, the schema
  # kept only when it is small enough to draft from, and whether the site
  # marks the tool as one that only reads.
  defp shaped_tool(%{"name" => name} = tool) when is_binary(name) do
    description = if is_binary(tool["description"]), do: tool["description"], else: ""

    [
      %{
        name: String.slice(name, 0, 128),
        description: String.slice(description, 0, 1_000),
        input_schema: bounded_schema(tool["inputSchema"]),
        read_only?: marked_read_only?(tool)
      }
    ]
  end

  defp shaped_tool(_not_a_tool), do: []

  # Read-only only when the site says so outright and does not also say the
  # tool destroys anything. A tool it leaves unmarked is not read-only.
  defp marked_read_only?(%{"annotations" => %{"readOnlyHint" => true} = marks}),
    do: marks["destructiveHint"] != true

  defp marked_read_only?(_unmarked), do: false

  defp bounded_schema(%{} = schema) do
    if byte_size(Jason.encode!(schema)) <= @max_schema_bytes, do: schema, else: nil
  end

  defp bounded_schema(_absent_or_not_an_object), do: nil

  defp notify(client, method) do
    message = %{jsonrpc: "2.0", method: method}
    Req.post(client.target.url, [json: message] ++ headers(client) ++ client.target.options)
  end

  # One request, one answer: the JSON-RPC result, or the error the server or
  # the transport gave. A session id the server issues comes back with it.
  defp request(client, method, params) do
    id = System.unique_integer([:positive])
    message = %{jsonrpc: "2.0", id: id, method: method, params: params}

    options =
      [json: message, receive_timeout: @call_timeout_ms] ++
        headers(client) ++ client.target.options

    case Req.post(client.target.url, options) do
      {:ok, %Req.Response{status: 200} = response} ->
        with {:ok, reply} <- decode(response, id) do
          {:ok, reply, session_of(response) || client.session}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:status, status}}

      {:error, %{reason: reason}} ->
        {:error, reason}

      {:error, _other} ->
        {:error, :request_failed}
    end
  end

  defp headers(client) do
    accept = [{"accept", "application/json, text/event-stream"}]
    session = if client.session, do: [{"mcp-session-id", client.session}], else: []
    [headers: accept ++ session]
  end

  defp session_of(response) do
    case Req.Response.get_header(response, "mcp-session-id") do
      [session | _] when byte_size(session) <= 512 -> session
      _none -> nil
    end
  end

  # The body arrives as the bounded iodata the target read; a JSON answer
  # is decoded whole, an event stream is read for the one message that
  # answers this request.
  defp decode(response, id) do
    body = IO.iodata_to_binary(response.body || "")

    content_type =
      response
      |> Req.Response.get_header("content-type")
      |> List.first("")
      |> String.downcase()

    cond do
      Map.get(response.private, :assist_cut) == true ->
        {:error, :answer_too_long}

      String.starts_with?(content_type, "text/event-stream") ->
        body
        |> String.split(~r/\r?\n\r?\n/)
        |> Enum.flat_map(&event_data/1)
        |> Enum.find_value({:error, :not_json_rpc}, &reply(&1, id))

      true ->
        case Jason.decode(body) do
          {:ok, message} -> reply(message, id) || {:error, :not_json_rpc}
          {:error, _} -> {:error, :not_json_rpc}
        end
    end
  end

  defp event_data(event) do
    data =
      event
      |> String.split(~r/\r?\n/)
      |> Enum.flat_map(fn
        "data:" <> rest -> [String.trim_leading(rest, " ")]
        _other_field -> []
      end)
      |> Enum.join("\n")

    case Jason.decode(data) do
      {:ok, message} when is_map(message) -> [message]
      _not_json -> []
    end
  end

  defp reply(%{"jsonrpc" => "2.0", "id" => id, "result" => result}, id) when is_map(result),
    do: {:ok, result}

  defp reply(%{"jsonrpc" => "2.0", "id" => id, "error" => error}, id) when is_map(error),
    do:
      {:error,
       {:rpc_error, error["code"], String.slice(to_string(error["message"] || ""), 0, 500)}}

  defp reply(_other_message, _id), do: nil
end
