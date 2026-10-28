defmodule PatchbayWeb.MCPEventsTest do
  @moduledoc """
  How many update subscriptions `events/subscribe` lets in: an account holds at
  most 20 live ones, whichever connection made them, and one callback host
  receives at most 100 from every account together. A new subscription past
  either is refused before its callback is sent anything, and so is bringing
  back one that has run out; refreshing a live one is never refused; one that
  has run out frees its place.

  A subscription the cap lets through goes on to its callback's challenge.
  Each such callback here is on `localhost`, which resolves on this machine
  and is refused as not public, so nothing leaves the machine and the answer
  is a callback error rather than the cap's refusal.
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

  describe "one callback host" do
    setup do
      for _ <- 1..100,
          do: seed!(Principal.for_profile(Ash.UUID.generate()), "https://OcalHost/in")

      :ok
    end

    test "receives 100 from every account together, however its name is written" do
      for url <- ["https://ocalhost/other", "https://OCALHOST:8443/in?x=1"] do
        answer = Events.subscribe(params(url), actor())
        assert refused?(answer, "callback_host_full")
        {:error, _code, message, _data} = answer
        assert message == "ocalhost already receives 100 event subscriptions from Patchbay."
      end

      assert count() == 100
    end

    test "is only the host the address names, not a name that holds it or a path" do
      for url <- ["https://localhost/ocalhost", "https://localhost/in"] do
        assert past_the_cap?(Events.subscribe(params(url), actor()))
      end
    end
  end
end
