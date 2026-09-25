defmodule Patchbay.Assist.ReadOnlyTools do
  @moduledoc """
  Whether Patchbay calls a site's tool on a customer's behalf, or only
  suggests the call.

  A call is made only when both of these hold:

  - the tool is on Patchbay's own list of tools it has checked only read,
    kept in source under `config :patchbay, :assist_read_only_tools` as a
    map from a site's host to the names of its tools, and changed only by
    a reviewed change to that file;
  - the site's own answer marks the tool read-only and does not mark it
    destructive.

  A site's marks are its own claim and can be wrong, so they never put a
  tool on the list; they can only keep a listed one from being called. Every
  other tool, known or not, marked or not, is suggested with the reason.
  """

  alias Patchbay.Assist.McpClient

  @doc """
  `:call` when the tool named `tool` on the site at `host` may be called on
  a customer's behalf; otherwise `{:suggest, why}`, where `why` says in
  plain words why it is only suggested.
  """
  @spec decide(String.t(), McpClient.tool()) :: :call | {:suggest, String.t()}
  def decide(host, %{name: name, read_only?: read_only?}) do
    cond do
      not read_only? ->
        {:suggest, "the site does not mark this tool as one that only reads"}

      name not in Map.get(listed(), host, []) ->
        {:suggest, "Patchbay has not yet checked that this tool only reads"}

      true ->
        :call
    end
  end

  defp listed, do: Application.fetch_env!(:patchbay, :assist_read_only_tools)
end
