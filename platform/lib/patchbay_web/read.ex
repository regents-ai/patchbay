defmodule PatchbayWeb.Read do
  @moduledoc """
  One read a LiveView shows, owned by whoever asked for it: an account, a
  wallet or a route. Taken from the Regent template; its
  `skills/ash-frontend/references/async-state.md` explains the pattern.

  Each start or clear moves the read to a new generation, and the task is
  named with it, so only the current generation's answer lands. A read that
  fails keeps its last good value as `:stale`, or is `:error` when there was
  none; it never shows as zero or empty.

  Assign `%Read{}` under the read's name in `mount/3` and hand every result on
  with `def handle_async({Read, _, _} = name, result, socket)`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [cancel_async: 2, start_async: 3]

  @type state :: :idle | :loading | :ready | :empty | :stale | :error

  defstruct state: :idle, owner: nil, value: nil, error: nil, read_at: nil, generation: 0

  @doc """
  Reads `name` for `owner`. `fun` returns `{:ok, value}` or `{:error, reason}`.
  A read already running is cancelled, so repeated refreshes land one answer.
  The last value stays on screen only while the owner is the same.
  """
  def start(socket, name, owner, fun) do
    read = Map.fetch!(socket.assigns, name)
    generation = read.generation + 1
    kept = if read.owner == owner, do: read, else: %__MODULE__{}

    socket
    |> cancel_async({__MODULE__, name, read.generation})
    |> assign(name, %{kept | state: :loading, owner: owner, error: nil, generation: generation})
    |> start_async({__MODULE__, name, generation}, fun)
  end

  @doc "Empties `name` when its owner leaves: navigation, sign-out or a wallet switch."
  def clear(socket, name) do
    read = Map.fetch!(socket.assigns, name)

    socket
    |> cancel_async({__MODULE__, name, read.generation})
    |> assign(name, %__MODULE__{generation: read.generation + 1})
  end

  @doc "Lands a `handle_async/3` result for the current generation; drops any other."
  def settle(socket, {__MODULE__, name, generation}, result) do
    case Map.fetch!(socket.assigns, name) do
      %__MODULE__{generation: ^generation} = read -> assign(socket, name, landed(read, result))
      _moved_on -> socket
    end
  end

  defp landed(read, {:ok, {:ok, value}}),
    do: %{read | state: state(value), value: value, error: nil, read_at: DateTime.utc_now()}

  defp landed(%{read_at: nil} = read, failure),
    do: %{read | state: :error, error: reason(failure)}

  defp landed(read, failure), do: %{read | state: :stale, error: reason(failure)}

  defp state(value) when value in [nil, [], %{}], do: :empty
  defp state(_value), do: :ready

  defp reason({:ok, {:error, reason}}), do: reason
  defp reason({:exit, reason}), do: reason
end
