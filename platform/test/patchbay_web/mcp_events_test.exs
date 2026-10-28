defmodule PatchbayWeb.MCPEventsTest do
  @moduledoc """
  How many update subscriptions `events/subscribe` lets in: an account holds at
  most 20 live ones, whichever connection made them. A new subscription past
  that is normally turned down before its callback is sent anything, and so is
  bringing back one that has run out; refreshing a live one is never refused;
  one that has run out frees its place, and is removed within the hour. Two
  sent at once at the edge cannot both get in.

  A subscription the cap lets through goes on to its callback's challenge,
  answered here by `PatchbayWeb.CallbackStandIn`: a callback on `localhost` is
  refused as not public, so the answer is a callback error rather than the
  cap's refusal, and one on `answers.test` answers when the test says so.
  """

  use Patchbay.DataCase, async: false

  alias Patchbay.Agents.Actor
  alias Patchbay.Forum.EventSubscription
  alias Patchbay.Forum.Principal
  alias PatchbayWeb.MCP.Events

  defp actor do
    profile_id = Ash.UUID.generate()

    %Actor{
      id: profile_id,
      wallet_address: "0x" <> String.duplicate("c", 40),
      privy_user_id: "did:privy:events",
      pairing_id: Ash.UUID.generate(),
      beneficiary_profile_id: profile_id,
      principals: [Principal.for_profile(profile_id)]
    }
  end

  defp owner(actor), do: Principal.for_profile(actor.beneficiary_profile_id)

  defp params(url, arguments \\ %{}) do
    secret = "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))

    %{
      "name" => "reply_created",
      "arguments" => arguments,
      "delivery" => %{"mode" => "webhook", "url" => url, "secret" => secret}
    }
  end

  defp seed!(owner_id, url, opts \\ []) do
    arguments = Keyword.get(opts, :arguments, %{"thread_ids" => [Ash.UUID.generate()]})
    {:ok, id} = Regent.MCPEvents.subscription_id(owner_id, "reply_created", arguments, url)
    now = DateTime.utc_now()

    Ash.Seed.seed!(EventSubscription, %{
      id: id,
      owner_id: owner_id,
      name: "reply_created",
      arguments: arguments,
      url: url,
      secret_ciphertext: "sealed",
      expires_at: DateTime.add(now, Keyword.get(opts, :lives_seconds, 3600), :second),
      verified_at: now
    })
  end

  # Every account's subscriptions, which no one actor may read.
  defp count, do: EventSubscription |> Ash.read!(authorize?: false) |> length()

  defp refused?({:error, -32_000, _message, %{code: code}}, code), do: true
  defp refused?(_answer, _code), do: false

  # Let through: it went on to the callback's challenge.
  defp past_the_cap?({:error, -32_015, _message, _data}), do: true
  defp past_the_cap?(_answer), do: false

  describe "one account" do
    test "holds 20 live subscriptions, and the 21st is refused before anything is sent" do
      actor = actor()
      for n <- 1..20, do: seed!(owner(actor), "https://hooks-#{n}.example/in")

      answer = Events.subscribe(params("https://localhost/fresh"), actor)
      assert refused?(answer, "too_many_subscriptions")
      {:error, _code, message, _data} = answer
      assert message == "This account already has 20 event subscriptions."
      assert count() == 20
    end

    test "a refresh of one it has is never refused, and a lapsed one frees its place" do
      actor = actor()
      for n <- 1..19, do: seed!(owner(actor), "https://hooks-#{n}.example/in")
      seed!(owner(actor), "https://localhost/kept", arguments: %{})

      assert past_the_cap?(Events.subscribe(params("https://localhost/kept"), actor))

      lapsed = actor()
      for n <- 1..19, do: seed!(owner(lapsed), "https://hooks-#{n}.example/in")
      seed!(owner(lapsed), "https://old.example/in", lives_seconds: -1)

      assert past_the_cap?(Events.subscribe(params("https://localhost/fresh"), lapsed))
    end

    test "one that has run out cannot be brought back past the cap" do
      actor = actor()
      for n <- 1..20, do: seed!(owner(actor), "https://hooks-#{n}.example/in")
      seed!(owner(actor), "https://localhost/old", arguments: %{}, lives_seconds: -1)

      assert refused?(
               Events.subscribe(params("https://localhost/old"), actor),
               "too_many_subscriptions"
             )
    end

    test "another account's subscriptions do not count against it" do
      busy = actor()
      for n <- 1..20, do: seed!(owner(busy), "https://hooks-#{n}.example/in")

      assert past_the_cap?(Events.subscribe(params("https://localhost/fresh"), actor()))
    end
  end

  describe "two subscribes at once" do
    test "at the account's edge, only one gets in, though both passed the first look" do
      actor = Patchbay.AssistFixtures.paired_agent()
      for n <- 1..19, do: seed!(owner(actor), "https://hooks-#{n}.example/in")

      tasks =
        for n <- 1..2,
            do: Task.async(fn -> Events.subscribe(params("https://answers.test/#{n}"), actor) end)

      # Both have counted 19 and are at their callback's challenge.
      challenged =
        for _ <- tasks do
          assert_receive {:challenged, pid}, 5_000
          pid
        end

      for pid <- challenged, do: send(pid, :answer)
      answers = Enum.map(tasks, &Task.await(&1, 15_000))

      assert Enum.count(answers, &match?({:ok, %{"id" => _}}, &1)) == 1
      assert Enum.count(answers, &refused?(&1, "too_many_subscriptions")) == 1
      assert count() == 20
    end
  end

  describe "one that has run out" do
    test "is removed by the hourly look, and a live one stays" do
      actor = actor()
      live = seed!(owner(actor), "https://kept.example/in")
      seed!(owner(actor), "https://old.example/in", lives_seconds: -1)

      AshOban.Test.schedule_and_run_triggers({EventSubscription, :forget_lapsed})

      assert [%{id: id}] = EventSubscription |> Ash.read!(authorize?: false)
      assert id == live.id
    end
  end
end
