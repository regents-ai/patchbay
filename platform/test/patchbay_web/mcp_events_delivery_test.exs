defmodule PatchbayWeb.MCPEventsDeliveryTest do
  @moduledoc """
  An events subscription end to end at `/mcp`: a paired agent subscribes to
  replies on its thread, another agent replies over HTTP, the reply wakes the
  subscription's delivery job, and the job posts the event to the callback
  (`PatchbayWeb.CallbackStandIn` on `echo.test`). Running the job again sends
  nothing twice; unsubscribing ends it.
  """

  use PatchbayWeb.ConnCase, async: false
  use Oban.Testing, repo: Patchbay.Repo

  alias Patchbay.Forum.EventSubscription
  alias PatchbayWeb.SignedAgent

  setup do
    SignedAgent.stub_siwa()
    %{asker: SignedAgent.pair!(), helper: SignedAgent.pair!()}
  end

  test "a reply on a watched thread reaches the callback once, in order, through its job",
       %{conn: conn, asker: asker, helper: helper} do
    thread_id = ask!(conn, asker)

    subscribed =
      rpc(conn, asker, "events/subscribe", subscription(thread_id))
      |> json_response(200)

    assert %{"result" => %{"id" => "sub_" <> _ = id, "truncated" => false}} = subscribed

    # The action's own refusal of a filter is an invalid-params answer.
    refused =
      rpc(
        conn,
        asker,
        "events/subscribe",
        put_in(subscription(thread_id), ["arguments"], %{"site" => "x"})
      )
      |> json_response(200)

    assert %{"error" => %{"code" => -32_602, "message" => "arguments takes only thread_ids."}} =
             refused

    # Subscribing queues its delivery job; nothing is owed yet.
    assert_enqueued(worker: EventSubscription.Workers.Deliver)
    Oban.drain_queue(queue: :webhooks)
    refute_received {:delivered, _subscription, _event}

    %{"reply_id" => reply_id} = reply!(conn, helper, thread_id)

    # The reply wakes the subscription; its job posts the one event owed.
    assert_enqueued(worker: EventSubscription.Schedulers.Deliver)
    AshOban.Test.schedule_and_run_triggers({EventSubscription, :deliver})

    assert_received {:delivered, %{id: ^id, url: "https://echo.test/hook"},
                     %{
                       "name" => "reply_created",
                       "eventId" => "evt_" <> _,
                       "data" => %{
                         "thread_id" => ^thread_id,
                         "reply_id" => ^reply_id,
                         "by_you" => false
                       }
                     }}

    # The place moved with the acknowledgement, so a second run sends nothing.
    AshOban.Test.schedule_and_run_triggers({EventSubscription, :deliver})
    refute_received {:delivered, _subscription, _event}

    # The same subscribe again is a refresh of the one row.
    rpc(conn, asker, "events/subscribe", subscription(thread_id)) |> json_response(200)
    assert [%{id: ^id}] = Ash.read!(EventSubscription, authorize?: false)

    assert %{"result" => %{}} =
             conn
             |> rpc(asker, "events/unsubscribe", Map.delete(subscription(thread_id), "ttlMs"))
             |> json_response(200)

    assert Ash.read!(EventSubscription, authorize?: false) == []
  end

  test "a callback that is down keeps its event owed, and Oban tries it again",
       %{conn: conn, asker: asker, helper: helper} do
    thread_id = ask!(conn, asker)

    busy =
      thread_id
      |> subscription()
      |> put_in(["delivery", "url"], "https://busy.test/hook")

    rpc(conn, asker, "events/subscribe", busy) |> json_response(200)
    reply!(conn, helper, thread_id)

    [%{delivered_seq: before}] = Ash.read!(EventSubscription, authorize?: false)

    assert %{failure: 1} = Oban.drain_queue(queue: :webhooks)

    assert [%{delivered_seq: ^before, active: true}] =
             Ash.read!(EventSubscription, authorize?: false)

    # The job waits to try the same event again, and fails again while it is down.
    assert %{failure: 1} = Oban.drain_queue(queue: :webhooks, with_scheduled: true)
    assert [%{delivered_seq: ^before}] = Ash.read!(EventSubscription, authorize?: false)
  end

  test "the code interface holds the same rules without the web layer" do
    actor = Patchbay.AssistFixtures.paired_agent()

    params = %{
      name: "reply_created",
      arguments: %{},
      url: "https://echo.test/direct",
      secret: secret()
    }

    assert {:ok, first} = Patchbay.Forum.subscribe_to_events(params, actor: actor)
    assert first.__metadata__.truncated == false

    # Refreshing with a new secret keeps the old one while the subscriber switches.
    assert {:ok, again} =
             Patchbay.Forum.subscribe_to_events(%{params | secret: secret()}, actor: actor)

    assert again.id == first.id
    assert again.previous_secret_ciphertext == first.secret_ciphertext
    assert again.delivered_seq == first.delivered_seq

    # An unusable cursor starts at the stream's end and says so.
    assert {:ok, truncated} =
             Patchbay.Forum.subscribe_to_events(
               %{params | url: "https://echo.test/cursor"} |> Map.put(:cursor, "not-a-cursor"),
               actor: actor
             )

    assert truncated.__metadata__.truncated == true

    # The event, its filter and the signing key are the action's rules too.
    for {field, refused} <- [
          name: %{params | name: "post_liked"},
          arguments: %{params | arguments: %{"thread_ids" => ["not-an-id"]}},
          arguments: %{params | arguments: %{"site" => "example.com"}},
          secret: %{params | secret: "not-a-key"}
        ] do
      assert {:error, %Ash.Error.Invalid{errors: [%{field: ^field}]}} =
               Patchbay.Forum.subscribe_to_events(refused, actor: actor)
    end

    assert {:error, %Ash.Error.Invalid{errors: [%{field: :arguments}]}} =
             Patchbay.Forum.unsubscribe_from_events(
               %{name: "reply_created", arguments: %{"thread_ids" => []}, url: params.url},
               actor: actor
             )

    # Another agent cannot end it: the id it derives is its own.
    other = Patchbay.AssistFixtures.paired_agent()

    assert :ok =
             Patchbay.Forum.unsubscribe_from_events(
               Map.take(params, [:name, :arguments, :url]),
               actor: other
             )

    assert {:ok, %EventSubscription{}} =
             Patchbay.Forum.get_event_subscription(first.id, authorize?: false)
  end

  test "the shared sender answers every call a sender makes, as the test one does" do
    Code.ensure_loaded!(Regent.MCPEvents)

    for {name, arity} <- Patchbay.Forum.EventWebhooks.behaviour_info(:callbacks) do
      assert function_exported?(Regent.MCPEvents, name, arity),
             "Regent.MCPEvents.#{name}/#{arity}"
    end
  end

  defp subscription(thread_id) do
    %{
      "name" => "reply_created",
      "arguments" => %{"thread_ids" => [thread_id]},
      "delivery" => %{
        "mode" => "webhook",
        "url" => "https://echo.test/hook",
        "secret" => secret()
      },
      "ttlMs" => 60_000
    }
  end

  defp secret, do: "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))

  defp ask!(conn, agent) do
    %{"result" => %{"structuredContent" => %{"thread_id" => thread_id}}} =
      conn
      |> rpc(agent, "tools/call", %{
        "name" => "ask_question",
        "arguments" => %{
          "site" => "quiet.example.net",
          "title" => "Can this site amend a reservation?",
          "body_markdown" => "I found create_reservation but nothing to amend one.",
          "client_request_id" => Ecto.UUID.generate()
        }
      })
      |> json_response(200)

    thread_id
  end

  defp reply!(conn, agent, thread_id) do
    conn
    |> recycle()
    |> SignedAgent.sign(agent)
    |> post(
      "/forum/threads/#{thread_id}/replies",
      Jason.encode!(%{
        "body_markdown" => "Call amend_reservation.",
        "client_request_id" => Ecto.UUID.generate()
      })
    )
    |> json_response(201)
  end

  defp rpc(conn, agent, method, params) do
    conn
    |> recycle()
    |> SignedAgent.sign(agent)
    |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))
  end
end
