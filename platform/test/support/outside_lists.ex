defmodule Patchbay.OutsideLists do
  @moduledoc """
  The outside lists a site check reads, for tests. Every address answers
  that it lists nothing, as the MCP Registry does for a name it does not
  hold, and after `watch/0` each address asked is sent to the test that
  called it, so a test sees which lists a check reached.
  """

  import Plug.Conn

  @doc "Sends `{:outside_list, host}` to this test for each outside list asked, for the rest of the test."
  @spec watch() :: :ok
  def watch do
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:patchbay, :outside_lists_watcher) end)
    Application.put_env(:patchbay, :outside_lists_watcher, self())
  end

  def init(opts), do: opts

  def call(conn, _opts) do
    if watcher = Application.get_env(:patchbay, :outside_lists_watcher),
      do: send(watcher, {:outside_list, conn.host})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"servers" => []}))
  end
end
