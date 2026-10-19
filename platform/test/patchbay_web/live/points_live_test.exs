defmodule PatchbayWeb.PointsLiveTest do
  @moduledoc """
  The Points page before and after earning opens. Earning is set in the
  application's `:regent_points` settings, so this file runs alone.
  """

  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PatchbayWeb.Plugs.CurrentProfile
  alias PatchbayWeb.SignedAgent

  test "once earning opens with a daily rule, the page shows one daily limit for the person and their agents",
       %{conn: conn} do
    earn_on("patchbay.report_published")

    {:ok, view, _html} = live(conn, ~p"/points")

    assert has_element?(view, "#points-signed-out")
    assert has_element?(view, ~s(.pb-account-tabs a[href="/points"][aria-current="page"]))
    assert has_element?(view, "#points-earn dt", "You and your agents")
    assert has_element?(view, "#points-earn dd", "Up to 100 a day on Patchbay")
  end

  test "while earning is off, a signed-in person sees their balance and no bonus is read or shown",
       %{conn: conn} do
    person = SignedAgent.pair!().owner
    conn = conn |> Plug.Test.init_test_session(%{}) |> CurrentProfile.sign_in(person.id)

    {:ok, view, _html} = live(conn, ~p"/points")
    render_async(view)

    assert has_element?(view, "#account-points-summary")
    assert has_element?(view, "#points-earn", "Earning hasn’t opened yet.")
    refute has_element?(view, "#points-bonus")
  end

  # Any installed source makes a rule count as tracked; nothing is awarded here.
  defp earn_on(rule) do
    config = Application.get_all_env(:regent_points)

    Application.put_env(:regent_points, :starts_at, DateTime.add(DateTime.utc_now(), -1, :day))
    Application.put_env(:regent_points, :approved_rules, [rule])

    Application.put_env(
      :regent_points,
      :adapters,
      Map.put(config[:adapters], rule, Patchbay.Points.CreditsPurchase)
    )

    on_exit(fn ->
      Enum.each(config, fn {key, value} -> Application.put_env(:regent_points, key, value) end)
    end)
  end
end
