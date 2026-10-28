defmodule PatchbayWeb.AnimationsLiveTest do
  # The motion lab holds at most 12 notes, leaving ones included, so presses
  # sent faster than notes leave cannot grow one open page without end.
  use PatchbayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "a burst of Send a note presses keeps at most 12 notes on the page", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/animations")

    for _ <- 1..40, do: render_click(view, "toast", %{})

    notes = Regex.scan(~r/\sid="lab-toast-\d+"/, render(view))
    assert length(notes) in 4..12
  end
end
