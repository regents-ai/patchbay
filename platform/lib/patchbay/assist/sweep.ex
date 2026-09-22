defmodule Patchbay.Assist.Sweep do
  @moduledoc """
  At boot, closes the runs the last process died in the middle of, before
  the runner starts taking new ones.

  It runs once, in the supervisor's own start, and stays out of the tree:
  a runner that restarts later does not sweep, so the runs its workers are
  still finishing are left alone.
  """

  alias Patchbay.Assist

  @doc false
  def child_spec(_opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :transient}

  @doc false
  @spec start_link() :: :ignore
  def start_link do
    :ok = Assist.interrupt_open_runs()
    :ignore
  end
end
