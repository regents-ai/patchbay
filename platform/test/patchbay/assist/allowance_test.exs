defmodule Patchbay.Assist.AllowanceTest do
  @moduledoc """
  Free fixes from the page: one a day for each connection, two more a day
  once signed in, counted from the runs themselves; a free run opens only
  under the grant that is left; and a run is read back by the browser that
  asked for it or the person who did, and by nobody else.
  """

  use Patchbay.DataCase, async: false

  alias Patchbay.Assist
  alias Patchbay.Assist.Allowance
  alias Patchbay.Identity

  @request %{
    "goal" => "Book the 9am table for two on Friday",
    "site_url" => "https://bookings.example.com/app",
    "believed_calls" => [],
    "sign_in" => "unknown",
    "expected_result" => "A confirmation with a booking reference"
  }

  test "a connection has one free fix a day, and a signed-in person two more" do
    key = key()
    person = person()

    assert Allowance.remaining(key, nil) == %{free: 1, sign_in_adds: 2}
    assert Allowance.remaining(key, person) == %{free: 3, sign_in_adds: 0}
    assert Allowance.grant(key, nil) == {:ok, :visitor}

    # The connection's own fix goes first, whoever is signed in.
    {:ok, first} = Assist.request_free_run(@request, :visitor, key, browser(), person)
    assert first.grant == :visitor
    assert first.visitor_key == key
    assert first.payer_profile_id == person.id
    assert first.status == :paid
    assert is_nil(first.payment_intent_id)
    # No fee, so nothing for the operator to forward.
    assert first.deposit_status == :no_fee
    close(first)

    assert Allowance.remaining(key, nil) == %{free: 0, sign_in_adds: 2}
    assert Allowance.grant(key, nil) == :none
    assert Allowance.remaining(key, person) == %{free: 2, sign_in_adds: 0}
    assert Allowance.grant(key, person) == {:ok, :member}

    # Then the person's own two, once the connection's is used.
    {:ok, second} = Assist.request_free_run(@request, :member, key, browser(), person)
    close(second)
    {:ok, third} = Assist.request_free_run(@request, :member, key, browser(), person)
    close(third)

    assert Allowance.remaining(key, person) == %{free: 0, sign_in_adds: 0}
    assert Allowance.grant(key, person) == :none

    # Another connection still has its own.
    assert Allowance.grant(key(), person) == {:ok, :visitor}
  end

  test "a free run opens only under the grant the allowance gives, and never without one" do
    key = key()
    person = person()

    # Not the person's grant while the connection's is left.
    assert {:error, %Ash.Error.Forbidden{}} =
             Assist.request_free_run(@request, :member, key, browser(), person)

    # Not the person's grant without a person.
    assert {:error, %Ash.Error.Forbidden{}} =
             Assist.request_free_run(@request, :member, key, browser(), nil)

    {:ok, run} = Assist.request_free_run(@request, :visitor, key, browser(), nil)
    close(run)

    # The connection's fix is used, and nobody is signed in.
    assert {:error, %Ash.Error.Forbidden{}} =
             Assist.request_free_run(@request, :visitor, key, browser(), nil)

    # A paid grant is not a free run's to claim.
    assert {:error, %Ash.Error.Invalid{}} =
             Assist.request_free_run(@request, :paid, key(), browser(), nil)
  end

  test "one open run per browser is the database's rule" do
    browser = browser()
    {:ok, _first} = Assist.request_free_run(@request, :visitor, key(), browser, nil)

    assert {:error, %Ash.Error.Invalid{}} =
             Assist.request_free_run(@request, :visitor, key(), browser, nil)
  end

  test "a run is read by its browser or its person, and an anonymous read finds nothing" do
    browser = browser()
    person = person()
    {:ok, mine} = Assist.request_free_run(@request, :visitor, key(), browser, nil)
    {:ok, theirs} = Assist.request_free_run(@request, :visitor, key(), browser(), person)

    assert {:ok, %{id: id}} = Assist.get_run_as_browser(mine.id, browser)
    assert id == mine.id
    assert {:ok, nil} = Assist.get_run_as_browser(theirs.id, browser)

    assert {:ok, %{id: id}} = Assist.get_run(theirs.id, actor: person, not_found_error?: false)
    assert id == theirs.id
    assert {:ok, nil} = Assist.get_run(mine.id, actor: person, not_found_error?: false)

    # Without an actor there is no payer to match: a run asked for without
    # signing in is not everybody's to read.
    assert {:error, %Ash.Error.Forbidden{}} = Assist.get_run(mine.id, actor: nil)
    assert {:error, %Ash.Error.Forbidden{}} = Assist.get_run(mine.id)
  end

  test "a change to a run is announced on its channel" do
    {:ok, run} = Assist.request_free_run(@request, :visitor, key(), browser(), nil)
    Phoenix.PubSub.subscribe(Patchbay.PubSub, Patchbay.Assist.Run.topic(run.id))

    {:ok, _noted} = Assist.record_step(run, %{"note" => "Looking."}, authorize?: false)
    assert_receive {:assist_run_changed, id}
    assert id == run.id
  end

  # Closing a run the way Patchbay's own worker does, so the next may open.
  defp close(run) do
    # The worker's own moves on the run it works on.
    {:ok, running} = Assist.start_run(run, authorize?: false)

    # Same: the worker closing its own run.
    {:ok, _done} =
      Assist.finish_run(running, %{status: :finished, outcome: :not_possible}, authorize?: false)
  end

  defp key, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  defp browser, do: Ash.UUID.generate()

  defp person do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:free-#{Ecto.UUID.generate()}",
      wallet_address: "0x" <> String.duplicate("b", 40)
    })
  end
end
