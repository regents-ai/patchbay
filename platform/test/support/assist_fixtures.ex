defmodule Patchbay.AssistFixtures do
  @moduledoc """
  Assists for tests. `paired_agent/0` is a SIWA-signed agent paired with a
  person, as the agent door signs it in, for tests that open free runs the
  way that door does. `browser_run/1` writes a run straight into the table in
  the shape a free run asked from the page left behind: open, asked by a
  browser and, when `payer_profile_id` is given, by a signed-in person.
  """

  alias Patchbay.Agents.Actor
  alias Patchbay.Assist.Run
  alias Patchbay.Identity
  alias PatchbayWeb.SignedAgent

  @doc "The request every fixture run asks for."
  def request do
    %{
      "goal" => "Book the 9am table for two on Friday",
      "site_url" => "https://bookings.example.com/app",
      "error" => nil,
      "believed_calls" => [],
      "sign_in" => "unknown"
    }
  end

  @doc "A SIWA-signed agent paired with a new person."
  def paired_agent do
    %{owner: owner, account: account, wallet: wallet, pairing: pairing} = SignedAgent.pair!()
    profile = Identity.upsert_from_wallet!(%{wallet_address: wallet})
    Actor.new(profile, owner, account, pairing)
  end

  @doc "An open run the page asked for, with `attrs` over the defaults."
  def browser_run(attrs \\ %{}) do
    request = request()

    Ash.Seed.seed!(
      Run,
      Map.merge(
        %{
          browser_session_id: Ash.UUID.generate(),
          grant: :visitor,
          visitor_key: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
          deposit_status: :no_fee,
          goal: request["goal"],
          site_url: request["site_url"],
          sign_in: :unknown,
          believed_calls: []
        },
        attrs
      )
    )
  end
end
