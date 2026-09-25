defmodule PatchbayWeb.FixLiveTest do
  @moduledoc """
  The live fix page: the browser that asked for a fix watches it as each
  step is written and gets the answer for its agent at the end; a signed-in
  person sees the fix they asked for; anyone else is sent to the front.
  """

  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Assist
  alias Patchbay.Identity
  alias PatchbayWeb.Plugs.CurrentProfile

  @request %{
    "goal" => "Book the 9am table for two on Friday",
    "site_url" => "https://bookings.example.com/app",
    "believed_calls" => [],
    "sign_in" => "unknown",
    "expected_result" => "A confirmation with a booking reference"
  }

  test "the browser that asked follows the fix to its answer", %{conn: conn} do
    browser = Ash.UUID.generate()
    {:ok, run} = Assist.request_free_run(@request, :visitor, key(), browser, nil)

    {:ok, view, html} = conn |> as_browser(browser) |> live(~p"/fixes/#{run.id}")
    assert html =~ "Queued"
    assert html =~ "site     https://bookings.example.com/app"
    refute has_element?(view, "#pb-fix-answer-text")

    # From here the test moves the run the way Patchbay's own worker does.
    {:ok, running} = Assist.start_run(run, authorize?: false)
    assert render(view) =~ "Jev is working on it"

    {:ok, noted} =
      Assist.record_step(
        running,
        %{
          "tool" => "reserve_table",
          "arguments" => %{"party" => 2},
          "call" => "made",
          "answer" => "Booked, reference R-42",
          "reading" => %{"verdict" => "reached", "confidence" => 0.9, "by" => "jev"}
        },
        # The worker's own step on its own run.
        authorize?: false
      )

    html = render(view)
    assert html =~ ~s(called   reserve_table {&quot;party&quot;:2})
    assert html =~ "answer   Booked, reference R-42"

    assert html =~
             "jev      reads the answer as what was asked for · 90% sure (a judgement, not a check)"

    # The worker closing its own run.
    {:ok, _done} =
      Assist.finish_run(noted, %{status: :finished, outcome: :reached}, authorize?: false)

    html = render(view)
    assert html =~ "Jev reads the site&#39;s answer below as what you asked for."
    assert has_element?(view, "#pb-fix-copy[data-copy-target=pb-fix-answer-text]")
    answer = view |> element("#pb-fix-answer-text") |> render()
    assert answer =~ "PATCHBAY FIX  #{PatchbayWeb.Endpoint.url()}/fixes/#{run.id}"
    assert answer =~ "outcome: reached"
    assert answer =~ "call made: reserve_table"
    assert answer =~ ~s(arguments: {&quot;party&quot;:2})
    assert answer =~ "site answered: Booked, reference R-42"
    assert answer =~ "jev&#39;s reading: what was asked for"
  end

  test "another browser is sent to the front, and the signed-in person who asked is not",
       %{conn: conn} do
    person = person()
    {:ok, run} = Assist.request_free_run(@request, :visitor, key(), Ash.UUID.generate(), person)

    assert {:error, {:redirect, %{to: "/"}}} =
             conn |> as_browser(Ash.UUID.generate()) |> live(~p"/fixes/#{run.id}")

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/fixes/not-a-run")

    {:ok, _view, html} = conn |> signed_in(person) |> live(~p"/fixes/#{run.id}")
    assert html =~ "goal     Book the 9am table"
  end

  defp as_browser(conn, browser) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> put_session("forum_session_id", browser)
  end

  defp signed_in(conn, person) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> put_session(CurrentProfile.session_key(), person.id)
  end

  defp key, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp person do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:fixlive-#{Ecto.UUID.generate()}",
      wallet_address: "0x" <> String.duplicate("e", 40)
    })
  end
end
