defmodule PatchbayWeb.CallbackStandIn do
  @moduledoc """
  Stands in for `Regent.MCPEvents`' callback challenge and webhook posts in
  tests (`config :patchbay, Patchbay.Forum.EventSubscription, :webhooks`), so
  no test sends anything to a callback address.

  - A callback on `answers.test` answers its challenge when the test says so:
    the subscribing process sends the test `{:challenged, pid}` and waits for
    `:answer`, so a test can hold several subscribes just before they save.
  - A callback on `echo.test` answers its challenge at once, and takes every
    event posted to it: the test is sent `{:delivered, subscription, event}`,
    the signing view and the envelope exactly as the real sender gets them.
  - A callback on `busy.test` answers its challenge at once and then is
    down: every event posted to it fails as a 503 would, so it stays owed.
  - A callback on `recovers.test` is down like `busy.test` until the test
    calls `recover/0`, then takes events like `echo.test`.
  - Every other callback is refused as not public, as the real challenge
    refuses `localhost`.
  """

  @behaviour Patchbay.Forum.EventWebhooks

  @impl true
  def verify_callback(_id, url, _secret) do
    case URI.parse(url).host do
      "answers.test" ->
        send(hd(Process.get(:"$callers")), {:challenged, self()})

        receive do
          :answer -> :ok
        end

      host when host in ["echo.test", "busy.test", "recovers.test"] ->
        :ok

      _other ->
        {:error, :non_public_callback}
    end
  end

  @impl true
  def deliver(subscription, event) do
    case URI.parse(subscription.url).host do
      "echo.test" ->
        send(test_process(), {:delivered, subscription, event})
        :ok

      "busy.test" ->
        {:retry, {:http_status, 503}}

      "recovers.test" ->
        if Application.get_env(:patchbay, __MODULE__) == :recovered do
          send(test_process(), {:delivered, subscription, event})
          :ok
        else
          {:retry, {:http_status, 503}}
        end

      _other ->
        {:stop, :non_public_callback}
    end
  end

  @doc "Brings `recovers.test` up for the rest of the calling test."
  @spec recover() :: :ok
  def recover do
    Application.put_env(:patchbay, __MODULE__, :recovered)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:patchbay, __MODULE__) end)
  end

  # The test itself, whether the job runs in it or in a process it started.
  defp test_process, do: List.last([self() | Process.get(:"$callers", [])])
end
