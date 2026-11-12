defmodule Patchbay.SharedChangesTest do
  # Invariant: a pairing change announced through the shared database reaches
  # Patchbay's pages over Patchbay.SharedChanges' one listening connection. The
  # notice commits, as it does on a live site, so the listener hears it the way
  # every other site would.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox

  test "a pairing change announced on any site reaches Patchbay's pages" do
    privy_user_id = "did:privy:heard-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Patchbay.PubSub, RegentAgents.topic(privy_user_id))

    Sandbox.unboxed_run(Patchbay.Repo, fn -> RegentAgents.announce(privy_user_id) end)

    assert_receive :agents_changed
    refute_receive :agents_changed
  end
end
