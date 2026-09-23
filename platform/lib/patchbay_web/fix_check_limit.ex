defmodule PatchbayWeb.FixCheckLimit do
  @moduledoc """
  Counts, for each connection, the different addresses the free fix was
  pointed at where Patchbay found no WebMCP tools, and stops checking for a
  connection that has had more than three of those in the hour. Every check a
  connection asks for is also counted, so the check is never a way to have
  Patchbay fetch pages in bulk.

  It lives in this node's memory, which is the whole of Patchbay: the site
  runs on one machine.
  """

  use Hammer, backend: :ets

  @misses_allowed 3
  @miss_window :timer.hours(1)
  @checks_allowed 30
  @check_window :timer.minutes(10)

  @doc "Draws one check for the connection; `{:wait, seconds}` when it may not check now."
  @spec draw(String.t()) :: :ok | {:wait, pos_integer()}
  def draw(visitor) do
    with {:allow, _misses} <- hit({:miss, visitor}, @miss_window, @misses_allowed, 0),
         {:allow, _checks} <- hit({:check, visitor}, @check_window, @checks_allowed) do
      :ok
    else
      {:deny, wait} -> {:wait, seconds(wait)}
    end
  end

  @doc """
  Counts an address without tools against the connection, once however
  often it is asked about: how many the connection has had this hour, or
  `{:wait, seconds}` once that is more than three.
  """
  @spec missed(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:wait, pos_integer()}
  def missed(visitor, site_url) do
    counted =
      case hit({:missed, visitor, site_url}, @miss_window, 1) do
        {:allow, _first_time} -> 1
        {:deny, _counted_before} -> 0
      end

    case hit({:miss, visitor}, @miss_window, @misses_allowed, counted) do
      {:allow, misses} -> {:ok, misses}
      {:deny, wait} -> {:wait, seconds(wait)}
    end
  end

  @doc "How many addresses without tools the connection has had this hour."
  @spec misses(String.t()) :: non_neg_integer()
  def misses(visitor), do: get({:miss, visitor}, @miss_window)

  defp seconds(wait), do: wait |> div(1000) |> max(1)
end
