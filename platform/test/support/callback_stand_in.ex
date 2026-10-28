defmodule PatchbayWeb.CallbackStandIn do
  @moduledoc """
  Stands in for `Regent.MCPEvents`' callback challenge in tests
  (`config :patchbay, PatchbayWeb.MCP.Events, :callbacks`), so no test sends
  anything to a callback address.

  A callback on `answers.test` answers its challenge when the test says so:
  the subscribing process sends the test `{:challenged, pid}` and waits for
  `:answer`, so a test can hold several subscribes just before they save.
  Every other callback is refused as not public, as the real challenge
  refuses `localhost`.
  """

  @spec verify_callback(String.t(), String.t(), String.t()) :: :ok | {:error, atom()}
  def verify_callback(_id, url, _secret) do
    case URI.parse(url).host do
      "answers.test" ->
        send(hd(Process.get(:"$callers")), {:challenged, self()})

        receive do
          :answer -> :ok
        end

      _other ->
        {:error, :non_public_callback}
    end
  end
end
