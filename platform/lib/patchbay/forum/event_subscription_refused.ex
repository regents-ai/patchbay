defmodule Patchbay.Forum.EventSubscriptionRefused do
  @moduledoc """
  Why an events subscription was not saved. Every door that offers
  subscriptions answers with the reason: the hosted MCP server maps it to its
  JSON-RPC error.

    * `:too_many_subscriptions`: the account already holds
      `Patchbay.Forum.EventSubscription.per_account/0` live ones.
    * `{:callback, reason}`: the callback address is not one Patchbay may
      post to, or it did not answer its challenge. `reason` is the one
      `Regent.MCPEvents.callback_error/1` names.
  """

  use Splode.Error, fields: [:reason], class: :invalid

  @type reason :: :too_many_subscriptions | {:callback, atom()}

  def message(%{reason: :too_many_subscriptions}),
    do:
      "This account already has #{Patchbay.Forum.EventSubscription.per_account()} event subscriptions."

  def message(%{reason: {:callback, reason}}),
    do: "The callback address was refused: #{reason}."
end
