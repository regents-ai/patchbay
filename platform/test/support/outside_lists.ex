defmodule Patchbay.OutsideLists do
  @moduledoc """
  The lists a site check searches, for tests: the MCP Registry, GitHub and
  npm each answer with what `answer/1` was given for them, and with nothing
  found otherwise.
  """

  import Plug.Conn

  @lists %{
    "registry.modelcontextprotocol.io" => {:registry, %{"servers" => []}},
    "api.github.com" => {:github, %{"items" => []}},
    "registry.npmjs.org" => {:npm, %{"objects" => []}}
  }

  @doc "Has `list` (`:registry`, `:github` or `:npm`) answer `status` and `body` for the rest of the test."
  @spec answer(atom(), pos_integer(), map()) :: :ok
  def answer(list, status, body) do
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:patchbay, :outside_lists) end)
    answers = Application.get_env(:patchbay, :outside_lists, %{})
    Application.put_env(:patchbay, :outside_lists, Map.put(answers, list, {status, body}))
  end

  def init(opts), do: opts

  def call(conn, _opts) do
    {list, nothing} = Map.fetch!(@lists, conn.host)
    answers = Application.get_env(:patchbay, :outside_lists, %{})
    {status, body} = Map.get(answers, list, {200, nothing})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
