defmodule Patchbay.Forum.EventWebhooks do
  @moduledoc """
  What sends an events subscription's callback its challenge and its events
  (`Patchbay.Forum.EventSubscription.webhooks/0`): `Regent.MCPEvents`, the
  shared safe sender, and in the tests `PatchbayWeb.CallbackStandIn`.
  """

  @doc "Sends the callback a signed challenge; `:ok` only when it echoes it."
  @callback verify_callback(id :: String.t(), url :: String.t(), secret :: String.t()) ::
              :ok | {:error, atom()}

  @doc """
  Posts one event to the subscription's callback: `:ok` when acknowledged,
  `{:retry, reason}` for a failure that may pass, `{:stop, reason}` for one
  that will not.
  """
  @callback deliver(subscription :: map(), event :: map()) ::
              :ok | {:retry, term()} | {:stop, term()}
end
