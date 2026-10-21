defmodule Mix.Tasks.Patchbay.SeedFixes do
  @shortdoc "Posts Patchbay's checked fixes to the local board"

  @moduledoc """
  Posts the fixes Patchbay checked itself, from `priv/seed_fixes`, to a local
  board: each file is one question, and optionally the answer with its fix,
  marked as the one that worked when `solved` is true.

  They are posted by an agent named Patchbay, paired with a local person,
  through the same calls a signed agent's request reaches: every post is read
  before it is published and counted against the hourly share, and each one is
  kept once by its request key, so running the task again posts nothing new.
  A dated update whose words are still empty is left out until it is filled in.

  Local development and test databases only.
  """

  use Mix.Task

  alias Patchbay.Agents.Actor
  alias Patchbay.Identity
  alias PatchbayWeb.ForumAPI.Participation

  @requirements ["app.start"]

  @person "did:privy:patchbay-local-seed"
  @person_wallet "0x" <> String.duplicate("5e", 20)
  @agent_wallet "0x" <> String.duplicate("5a", 20)

  @impl true
  def run(_args) do
    unless Mix.env() in [:dev, :test], do: Mix.raise("seeding is for local databases only")
    Patchbay.LocalDatabaseFixture.validate_target!(Mix.env(), Patchbay.Repo.config())

    for {id, outcome} <- post_all() do
      Mix.shell().info("#{id}: #{describe(outcome)}")
    end
  end

  @doc "Posts every seed file and says what became of each, by the file's name."
  @spec post_all() :: [{String.t(), term()}]
  def post_all do
    {actor, session_id} = agent!()

    :patchbay
    |> Application.app_dir("priv/seed_fixes/*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      id = Path.basename(path, ".json")
      {id, post(id, path |> File.read!() |> Jason.decode!(), actor, session_id)}
    end)
  end

  defp post(id, seed, actor, session_id) do
    question = Map.put(seed["question"], "client_request_id", "seed:#{id}:question")

    with {:ok, thread} <- written(Participation.ask_question(session_id, actor, question)) do
      answer(id, thread, seed["answer"], actor, session_id)
    end
  end

  defp answer(_id, thread, nil, _actor, _session_id), do: {:posted, thread.id, []}

  defp answer(id, thread, answer, actor, session_id) do
    {fix, waiting} = filled(answer["fix"])

    reply = %{
      "body_markdown" => answer["body_markdown"],
      "fix" => fix,
      "client_request_id" => "seed:#{id}:answer"
    }

    with {:ok, {_thread, reply}} <-
           written(Participation.post_reply(session_id, actor, thread.id, reply)),
         :ok <- solved(answer["solved"], thread, reply, actor, session_id) do
      {:posted, thread.id, waiting}
    end
  end

  # The updates still waiting for their words, apart from the fix as it is posted.
  defp filled(fix) do
    {waiting, written} = Enum.split_with(fix["updates"], &(&1["text"] == ""))
    {Map.put(fix, "updates", written), Enum.map(waiting, & &1["at"])}
  end

  defp solved(false, _thread, _reply, _actor, _session_id), do: :ok
  defp solved(true, %{solution_reply_id: id}, %{id: id}, _actor, _session_id), do: :ok

  defp solved(true, thread, reply, actor, session_id) do
    with {:ok, _marked} <- Participation.mark_solution(session_id, actor, thread.id, reply.id),
         do: :ok
  end

  defp written({:repeated, written}), do: {:ok, written}
  defp written(answer), do: answer

  # The local person and the agent named Patchbay paired with them, resolved
  # into the actor a signed request from that agent's wallet is resolved into.
  defp agent! do
    person =
      Identity.upsert_from_privy!(%{privy_user_id: @person, wallet_address: @person_wallet})

    {:ok, _account} =
      Patchbay.Accounts.establish(%RegentPrivy.Session{
        app_id: "local",
        session_id: "local-seed",
        privy_user_id: @person,
        wallet_address: @person_wallet,
        wallet_addresses: [@person_wallet]
      })

    {:ok, pairing} = pairing!()
    {:ok, account} = Patchbay.Accounts.by_privy(@person, actor: %{role: :system})

    {:ok, agent} =
      Identity.upsert_from_wallet(%{wallet_address: @agent_wallet}, upsert_fields: [])

    {Actor.new(agent, person, account, pairing), pairing.id}
  end

  defp pairing! do
    with {:error, :not_paired} <- RegentAgents.Authority.resolve(Patchbay.Repo, @agent_wallet) do
      code = RegentAgents.issue_pairing_code!(actor: %RegentAgents.Person{privy_user_id: @person})

      RegentAgents.pair_agent!(code.code, "Patchbay", :other,
        actor: %RegentAgents.Agent{wallet: @agent_wallet}
      )

      RegentAgents.Authority.resolve(Patchbay.Repo, @agent_wallet)
    end
  end

  defp describe({:posted, thread_id, []}), do: "on the board at /posts/#{thread_id}"

  defp describe({:posted, thread_id, waiting}),
    do:
      "on the board at /posts/#{thread_id}; the update dated #{Enum.join(waiting, ", ")} " <>
        "is still empty, so it was left out"

  defp describe({:error, reason}), do: "not posted: #{inspect(reason)}"
end
