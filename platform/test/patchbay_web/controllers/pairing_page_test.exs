defmodule PatchbayWeb.PairingPageTest do
  @moduledoc """
  Pairing agents from a person's own profile page: only the owner sees their
  agents, asking for a code shows one that pairs an agent, and the owner, and
  nobody else, unpairs an agent.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Identity
  alias Patchbay.Identity.Pairing
  alias PatchbayWeb.Plugs.CurrentProfile

  setup do
    %{person: person("owner")}
  end

  test "only the owner sees their agents", %{conn: conn, person: person} do
    mine = conn |> signed_in(person) |> get(~p"/agents/#{person.public_id}") |> html_response(200)
    assert mine =~ ~s(id="patchbay-agents")
    assert mine =~ "No agents are paired with you yet."
    assert mine =~ "Pair an agent"
    # The page a pairing control answers with opens on this card.
    assert mine =~ ~s(action="/agents/#{person.public_id}/pairing#patchbay-agents")

    theirs =
      build_conn()
      |> signed_in(person("stranger"))
      |> get(~p"/agents/#{person.public_id}")
      |> html_response(200)

    refute theirs =~ "patchbay-agents"

    signed_out = build_conn() |> get(~p"/agents/#{person.public_id}") |> html_response(200)
    refute signed_out =~ "patchbay-agents"
  end

  test "pairing an agent shows a code that pairs it, and the agent is listed", %{
    conn: conn,
    person: person
  } do
    page =
      conn
      |> signed_in(person)
      |> post(~p"/agents/#{person.public_id}/pairing")
      |> html_response(200)

    assert page =~ "Give your agent this code:"
    assert page =~ "Make a new code"

    assert [_whole, code] =
             Regex.run(
               ~r"<code id=\"pb-pairing-code\" class=\"pb-pairing-code-value\">([A-Z2-9]{5}-[A-Z2-9]{5})</code>",
               page
             )

    # The code has its own Copy button.
    assert page =~ ~s(data-copy-target="pb-pairing-code")

    agent = agent()
    assert {:ok, _person} = Pairing.pair(agent, code)

    listed =
      build_conn()
      |> signed_in(person)
      |> get(~p"/agents/#{person.public_id}")
      |> html_response(200)

    assert listed =~ agent.agent_name
    assert listed =~ agent.wallet_address
    assert listed =~ "Unpair"
    assert listed =~ ~s(action="/agents/#{person.public_id}/unpair#patchbay-agents")
    refute listed =~ "No agents are paired with you yet."
  end

  test "the owner unpairs an agent; nobody else can", %{conn: conn, person: person} do
    agent = agent()
    {:ok, %{code: code}} = Pairing.issue(person)
    {:ok, _person} = Pairing.pair(agent, code)

    stranger = person("stranger")

    refused =
      build_conn()
      |> signed_in(stranger)
      |> post(~p"/agents/#{stranger.public_id}/unpair", %{agent: agent.public_id})
      |> html_response(200)

    assert refused =~ "That agent is not paired with you."
    assert Identity.get_profile!(agent.id).paired_person_id == person.id

    unknown =
      build_conn()
      |> signed_in(person)
      |> post(~p"/agents/#{person.public_id}/unpair", %{agent: "agt_unknown"})
      |> html_response(200)

    assert unknown =~ "That agent is not paired with you."

    unpaired =
      conn
      |> signed_in(person)
      |> post(~p"/agents/#{person.public_id}/unpair", %{agent: agent.public_id})

    assert redirected_to(unpaired) == "/agents/#{person.public_id}#patchbay-agents"
    assert is_nil(Identity.get_profile!(agent.id).paired_person_id)
  end

  test "a signed-out visitor is sent to sign in", %{conn: conn, person: person} do
    assert conn |> post(~p"/agents/#{person.public_id}/pairing") |> redirected_to() == "/profile"

    assert build_conn()
           |> post(~p"/agents/#{person.public_id}/unpair", %{agent: "agt_any"})
           |> redirected_to() == "/profile"
  end

  defp person(subject) do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:pairing-page-#{subject}-#{Ecto.UUID.generate()}",
      wallet_address: "0x" <> String.duplicate("f", 40)
    })
  end

  defp agent do
    wallet = "0x" <> (:crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower))
    Identity.upsert_from_wallet!(%{wallet_address: wallet})
  end

  defp signed_in(conn, profile) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(CurrentProfile.session_key(), profile.id)
  end
end
