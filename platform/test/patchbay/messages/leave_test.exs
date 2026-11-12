defmodule Patchbay.Messages.LeaveTest do
  @moduledoc """
  Leaving a message for Patchbay's team, through the actions every surface
  calls:

  - a signed-in person and a paired agent each leave one, recorded as the
    person, and for the agent as the agent too, and get its receipt;
  - who left it comes from the actor alone: no input can name a sender;
  - a suspended person, their agent's person aside, and a stranger leave none;
  - the topic, the text and reply_to are bounded, and nothing is kept when
    refused;
  - an agent's operation_id answers its first message again, and refuses any
    other use;
  - each person leaves 10 an hour, their agents' included, and each address 30;
  - only Patchbay's moderators read messages.
  """

  use Patchbay.DataCase, async: false

  import Patchbay.AssistFixtures, only: [paired_agent: 0]
  import Patchbay.ModeratorFixtures, only: [moderator: 0]

  alias Patchbay.Identity
  alias Patchbay.Limits.Spent
  alias Patchbay.Messages
  alias Patchbay.Messages.Message
  alias Patchbay.Messages.Refused

  setup do
    %{key: Ecto.UUID.generate()}
  end

  test "a person and a paired agent each leave a message as themselves", %{key: key} do
    person = person!()

    assert {:ok, %Message{} = left} =
             Messages.leave_message(
               %{topic: "agents", body: "Hello team", reply_to: "me@example.com"},
               actor: person,
               context: %{client_key: key}
             )

    assert Message.receipt(left) == %{id: left.id, topic: "agents", inserted_at: left.inserted_at}

    assert %{person_profile_id: sender, agent_profile_id: nil, operation_id: nil} =
             stored(left.id)

    assert sender == person.id

    agent = paired_agent()

    assert {:ok, %{replayed: false, receipt: %{id: id, topic: "watchdog"}}} =
             agent_leave(agent, "watchdog", %{body: "For my person"}, key)

    assert %{person_profile_id: sender, agent_profile_id: from, reply_to: nil} = stored(id)
    assert {sender, from} == {agent.beneficiary_profile_id, agent.id}
  end

  test "no input names the sender", %{key: key} do
    person = person!()
    other = person!()

    assert {:error, %Ash.Error.Invalid{}} =
             Messages.leave_message(
               %{topic: "agents", body: "Hi", person_profile_id: other.id},
               actor: person,
               context: %{client_key: key}
             )

    assert {:error, %Ash.Error.Invalid{}} =
             Messages.leave_message(
               %{topic: "agents", body: "Hi", operation_id: Ecto.UUID.generate()},
               actor: person,
               context: %{client_key: key}
             )

    assert count() == 0
  end

  test "a suspended person, a wallet that only signed in and nobody leave nothing", %{key: key} do
    suspended = person!()
    Identity.suspend_profile!(suspended, "Spam", actor: %{role: :system})
    wallet = Identity.upsert_from_wallet!(%{wallet_address: wallet()})

    for actor <- [Identity.get_profile!(suspended.id), wallet, nil] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Messages.leave_message(%{topic: "agents", body: "Hi"},
                 actor: actor,
                 context: %{client_key: key}
               )
    end

    assert {:error, %Ash.Error.Forbidden{}} =
             Messages.agent_leave_message(
               "agents",
               %{body: "Hi", operation_id: Ecto.UUID.generate()},
               actor: person!(),
               context: %{client_key: key}
             )

    assert count() == 0
  end

  test "the topic, the text and reply_to are bounded", %{key: key} do
    person = person!()

    for input <- [
          %{topic: "Not A Topic", body: "Hi"},
          %{topic: String.duplicate("a", 41), body: "Hi"},
          %{topic: "agents", body: ""},
          %{topic: "agents", body: String.duplicate("a", 2001)},
          %{topic: "agents", body: "Hi", reply_to: String.duplicate("a", 201)},
          %{topic: "agents", body: "Hi\u202Ethere"}
        ] do
      assert {:error, %Ash.Error.Invalid{}} =
               Messages.leave_message(input, actor: person, context: %{client_key: key})
    end

    agent = paired_agent()

    assert {:error, %Ash.Error.Invalid{}} = agent_leave(agent, "agents", %{body: "Hi"}, key, nil)
    assert {:error, %Ash.Error.Invalid{}} = agent_leave(agent, "agents", %{body: "Hi"}, key, "x")
    assert count() == 0
  end

  test "an agent's operation_id answers its first message again and refuses any other", %{
    key: key
  } do
    agent = paired_agent()
    operation = Ecto.UUID.generate()
    input = %{body: "Once", reply_to: "agent@example.com"}

    assert {:ok, %{replayed: false, receipt: receipt}} =
             agent_leave(agent, "agents", input, key, operation)

    assert {:ok, %{replayed: true, receipt: ^receipt}} =
             agent_leave(agent, "agents", input, key, operation)

    for {topic, other} <- [
          {"agents", %{body: "Other", reply_to: "agent@example.com"}},
          {"agents", %{body: "Once"}},
          {"watchdog", input}
        ] do
      assert {:error, %Ash.Error.Invalid{errors: [%Refused{code: "idempotency_conflict"}]}} =
               agent_leave(agent, topic, other, key, operation)
    end

    # Another agent's use of the same UUID is its own.
    assert {:ok, %{replayed: false}} =
             agent_leave(paired_agent(), "agents", input, key, operation)

    assert count() == 2
  end

  # Two calls with one operation_id at once: the second's write is refused by
  # the table's unique index, on the field `AgentLeave` reads it by.
  test "the table itself holds an agent's operation_id to one message", %{key: key} do
    agent = paired_agent()

    write = fn ->
      Messages.leave_message(%{topic: "agents", body: "Once"},
        actor: agent,
        private_arguments: %{operation_id: key},
        context: %{client_key: key}
      )
    end

    assert {:ok, _left} = write.()
    assert {:error, %Ash.Error.Invalid{errors: [%{field: :agent_profile_id}]}} = write.()
    assert count() == 1
  end

  test "a person leaves 10 an hour, their agent's included, and a retry spends none" do
    agent = paired_agent()
    person = Identity.get_profile!(agent.beneficiary_profile_id)
    operation = Ecto.UUID.generate()

    assert {:ok, _left} =
             agent_leave(agent, "agents", %{body: "1"}, Ecto.UUID.generate(), operation)

    for _retry <- 1..3 do
      assert {:ok, %{replayed: true}} =
               agent_leave(agent, "agents", %{body: "1"}, Ecto.UUID.generate(), operation)
    end

    for n <- 2..10 do
      assert {:ok, _left} =
               Messages.leave_message(%{topic: "agents", body: "#{n}"},
                 actor: person,
                 context: %{client_key: Ecto.UUID.generate()}
               )
    end

    assert {:error, %Ash.Error.Invalid{errors: [%Spent{field: :body}]}} =
             agent_leave(agent, "agents", %{body: "11"}, Ecto.UUID.generate())

    assert {:error, %Ash.Error.Invalid{errors: [%Spent{field: :body}]}} =
             Messages.leave_message(%{topic: "agents", body: "11"},
               actor: person,
               context: %{client_key: Ecto.UUID.generate()}
             )

    assert count() == 10
  end

  test "an address leaves 30 an hour, whoever is at it", %{key: key} do
    for _person <- 1..3, person = person!(), n <- 1..10 do
      assert {:ok, _left} =
               Messages.leave_message(%{topic: "agents", body: "#{n}"},
                 actor: person,
                 context: %{client_key: key}
               )
    end

    assert {:error, %Ash.Error.Invalid{errors: [%Spent{}]}} =
             Messages.leave_message(%{topic: "agents", body: "31"},
               actor: person!(),
               context: %{client_key: key}
             )

    assert count() == 30
  end

  test "only Patchbay's moderators read messages", %{key: key} do
    person = person!()
    agent = paired_agent()

    {:ok, left} =
      Messages.leave_message(%{topic: "agents", body: "Private"},
        actor: person,
        context: %{client_key: key}
      )

    for reader <- [person, person!(), agent, nil] do
      assert {:error, %Ash.Error.Forbidden{}} = Messages.list_messages(actor: reader)
    end

    assert {:ok, %{results: [%Message{id: id, person: %{id: sender}, agent: nil}]}} =
             Messages.list_messages(actor: moderator())

    assert {id, sender} == {left.id, person.id}
  end

  defp agent_leave(agent, topic, input, key, operation \\ Ecto.UUID.generate()) do
    Messages.agent_leave_message(topic, Map.put(input, :operation_id, operation),
      actor: agent,
      context: %{client_key: key}
    )
  end

  # Read as the test: every message, which only a moderator may read.
  defp stored(id), do: Ash.get!(Message, id, authorize?: false)
  # As above.
  defp count, do: Message |> Ash.read!(authorize?: false) |> length()

  defp person! do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:message-#{System.unique_integer([:positive])}",
      wallet_address: wallet()
    })
  end

  defp wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end
