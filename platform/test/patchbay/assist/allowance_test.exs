defmodule Patchbay.Assist.AllowanceTest do
  @moduledoc """
  Free fixes: two a day for a SIWA-signed agent's wallet, and none once the
  site has given its day's worth, counted from the runs themselves, the ones
  the page once gave out too; a free run opens only under the grant that is
  left; one open run per browser; and a run is read back by the browser that
  asked for it or the person who did, and by nobody else.
  """

  use Patchbay.DataCase, async: false

  import Patchbay.AssistFixtures

  alias Patchbay.Assist
  alias Patchbay.Assist.Allowance
  alias Patchbay.Identity

  test "an agent has two free fixes a day, and none past them" do
    agent = paired_agent()

    assert Allowance.agent_grant(agent) == {:ok, :agent}

    {:ok, first} = Assist.request_agent_free_run(request(), agent)
    assert first.grant == :agent
    assert first.payer_profile_id == agent.id
    assert first.status == :paid
    assert is_nil(first.payment_intent_id)
    # No fee, so nothing for the operator to forward.
    assert first.deposit_status == :no_fee
    close(first)

    {:ok, second} = Assist.request_agent_free_run(request(), agent)
    close(second)

    assert Allowance.agent_grant(agent) == :none

    assert {:error, %Ash.Error.Forbidden{}} =
             Assist.request_agent_free_run(request(), agent)

    # Another agent still has its own.
    assert Allowance.agent_grant(paired_agent()) == {:ok, :agent}
  end

  test "once the site has given its free fixes for the day, nobody gets one" do
    old = Application.get_env(:patchbay, :daily_free_fixes)
    Application.put_env(:patchbay, :daily_free_fixes, 3)
    on_exit(fn -> restore(:daily_free_fixes, old) end)

    # Free fixes the page gave out today, to a connection and to a signed-in
    # person, count toward the site's number.
    browser_run(%{status: :finished, outcome: :not_possible})

    browser_run(%{
      grant: :member,
      payer_profile_id: person().id,
      status: :finished,
      outcome: :not_possible
    })

    agent = paired_agent()
    {:ok, first} = Assist.request_agent_free_run(request(), agent)
    close(first)

    # Given out: an agent with fixes of its own left gets none.
    assert Allowance.agent_grant(agent) == :given_out
    assert Allowance.agent_grant(paired_agent()) == :given_out

    assert {:error, %Ash.Error.Forbidden{}} =
             Assist.request_agent_free_run(request(), agent)

    # The site's number is read on every ask: raised, there is one to give.
    Application.put_env(:patchbay, :daily_free_fixes, 4)
    assert Allowance.agent_grant(agent) == {:ok, :agent}
  end

  test "one open run per browser is the database's rule" do
    browser = Ash.UUID.generate()
    browser_run(%{browser_session_id: browser})

    assert_raise Ash.Error.Invalid, fn -> browser_run(%{browser_session_id: browser}) end
  end

  test "a run is read by its browser or its person, and an anonymous read finds nothing" do
    browser = Ash.UUID.generate()
    person = person()
    mine = browser_run(%{browser_session_id: browser})
    theirs = browser_run(%{grant: :member, payer_profile_id: person.id})

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
    run = browser_run()
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

  defp restore(setting, nil), do: Application.delete_env(:patchbay, setting)
  defp restore(setting, value), do: Application.put_env(:patchbay, setting, value)

  defp person do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:free-#{Ecto.UUID.generate()}",
      wallet_address: "0x" <> String.duplicate("b", 40)
    })
  end
end
