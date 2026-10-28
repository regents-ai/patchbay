defmodule PatchbayWeb.AnimationsLiveTest do
  # The motion lab holds at most 12 notes, leaving ones included, so presses
  # sent faster than notes leave cannot grow one open page without end.
  use PatchbayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  # The notes on the page, by number. The lab numbers them from 100.
  defp notes(view) do
    ~r/\sid="lab-toast-(\d+)"/
    |> Regex.scan(render(view), capture: :all_but_first)
    |> Enum.map(fn [id] -> String.to_integer(id) end)
  end

  test "a press past the 12th note is dropped", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/animations")

    # Faster than a leaving note takes to go, so all 12 are still held.
    for _ <- 1..13, do: render_click(view, "toast", %{})

    assert notes(view) == Enum.to_list(100..111)
  end

  test "a long burst of presses never holds more than 12 notes", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/animations")

    for _ <- 1..40, do: render_click(view, "toast", %{})

    assert length(notes(view)) in 4..12
  end
end
