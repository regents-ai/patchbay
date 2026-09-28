defmodule PatchbayWeb.ApiError do
  @moduledoc """
  The one shape every Patchbay refusal takes, whichever door answered it: an
  HTTP endpoint, a hosted MCP tool or a tool a page registers in the browser.

      {"error": {"code": "not_found", "message": "There is no report with that id.",
                 "hint": "Check the id, or search the board at /forum/search."}}

  `code` is a short stable word to branch on, `message` says what was refused
  and `hint` names the one thing to do about it. Anything else a refusal has
  to say, the lines a request broke, the seconds to wait, the id of a run
  already under way, sits inside `error` beside them; nothing stands beside
  `error` itself, so an agent that has read one refusal has read them all.
  """

  @doc "The refusal body; `extra` is whatever else it carries, inside `error`."
  @spec body(String.t(), String.t(), String.t(), map()) :: %{error: map()}
  def body(code, message, hint, extra \\ %{}) do
    %{error: Map.merge(extra, %{code: code, message: message, hint: hint})}
  end

  @doc "The refusal for input that broke the contract, one line per rule in `details`."
  @spec invalid([String.t()]) :: %{error: map()}
  def invalid(messages) do
    body(
      "invalid",
      Enum.join(messages, " "),
      "Correct the fields in details, then send it again.",
      %{details: messages}
    )
  end
end
