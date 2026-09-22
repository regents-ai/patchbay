defmodule Patchbay.Identity.Pairing do
  @moduledoc """
  Pairing an agent with a person, so that they share one balance of Patchbay
  Credits: the person buys, and the agent spends.

  The person, signed in, asks for a code and gives it to their agent. The
  agent sends the code back signed by its wallet, through a door that proves
  the wallet, and is paired with the person the code belongs to. The code
  pairs one agent, once, within ten minutes. Whatever the agent held on its
  own moves onto the person as it pairs. An agent is paired with one person at
  a time, and a code from another person moves it to them.

  The person can unpair an agent whenever they like. What was spent and
  bought stays on the person's balance, and the agent starts again from
  nothing of its own.
  """

  alias Patchbay.Identity
  alias Patchbay.Identity.AgentProfile
  alias Patchbay.Identity.PairingCode
  alias Patchbay.Payments.Credits

  # No letters or digits that read as one another: no I, L, O, 0 or 1.
  @alphabet ~c"ABCDEFGHJKMNPQRSTUVWXYZ23456789"
  @length 10

  @typedoc "A code as the person reads it, and when it stops standing."
  @type issued :: %{code: String.t(), expires_at: DateTime.t()}

  @doc "Gives `person` a new code, in place of any they had."
  @spec issue(AgentProfile.t()) :: {:ok, issued()} | {:error, term()}
  def issue(person) do
    code = new_code()

    with {:ok, issued} <-
           PairingCode
           |> Ash.Changeset.for_create(:issue, %{code_sha256: sha256(code)}, actor: person)
           |> Ash.create() do
      {:ok, %{code: written(code), expires_at: issued.expires_at}}
    end
  end

  @doc """
  Pairs wallet author `agent` with the person whose code it sent, and answers
  that person. A code that is unknown, used or past its ten minutes pairs
  nothing.
  """
  @spec pair(AgentProfile.t(), String.t()) ::
          {:ok, AgentProfile.t()} | {:error, :code_unknown | term()}
  def pair(agent, code) do
    Ash.transact([PairingCode, AgentProfile], fn ->
      # The pairing process's own read and writes, for the wallet that the
      # door calling this has already proven.
      with %PairingCode{person_id: person_id} = live <- live_code(code),
           :ok <- Credits.hold_for_pairing(agent.id, person_id),
           :ok <- Ash.destroy(live, action: :use_up, authorize?: false),
           {:ok, _paired} <-
             agent
             |> Ash.Changeset.for_update(:pair_with_person, %{person_id: person_id})
             |> Ash.update(authorize?: false),
           :ok <- Credits.move_to_person(agent.id, person_id) do
        Identity.get_profile!(person_id)
      end
    end)
    |> case do
      {:ok, :code_unknown} -> {:error, :code_unknown}
      paired -> paired
    end
  end

  @doc """
  The person a code would pair with, while it still stands, so the agent can
  be told whose code it is before it signs. Using the code is `pair/2`'s.
  """
  @spec person_for(term()) :: {:ok, AgentProfile.t()} | {:error, :code_unknown | term()}
  def person_for(code) do
    case live_code(code) do
      %PairingCode{person_id: person_id} -> Identity.get_profile(person_id)
      :code_unknown -> {:error, :code_unknown}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Ends the pairing of the agent with public id `agent_public_id`, when it is
  paired with `person`.
  """
  @spec unpair(AgentProfile.t(), String.t()) :: {:ok, AgentProfile.t()} | {:error, term()}
  def unpair(person, agent_public_id) do
    Ash.transact(AgentProfile, fn ->
      # Nothing is locked for an agent that is not the person's own.
      with {:ok, agent} <- Identity.get_profile_by_public_id(agent_public_id),
           {:ok, agent} <- paired_with(agent, person),
           :ok <- Credits.hold_for_pairing(agent.id, person.id),
           # Read again under the locks, so the pairing ended is the one there now.
           {:ok, agent} <- Identity.get_profile(agent.id),
           {:ok, unpaired} <- Identity.unpair(agent, actor: person) do
        unpaired
      end
    end)
  end

  @doc "The agents paired with `person`, most recent first."
  @spec agents(AgentProfile.t()) :: [AgentProfile.t()]
  def agents(person), do: Identity.paired_with_me!(actor: person)

  defp paired_with(%{paired_person_id: person_id} = agent, %{id: person_id}), do: {:ok, agent}
  defp paired_with(_agent, _person), do: {:error, Ash.Error.Forbidden.exception([])}

  # A code that pairs nothing writes nothing either, so it is answered as a
  # value the transaction can commit, rather than an error it would wrap.
  defp live_code(code) when is_binary(code) do
    PairingCode
    |> Ash.Query.for_read(:live, %{code_sha256: code |> readable() |> sha256()})
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> :code_unknown
      {:ok, live} -> live
      {:error, error} -> {:error, error}
    end
  end

  defp live_code(_code), do: :code_unknown

  # A code read back the way a person or an agent might copy it: in either
  # case, with or without the hyphen and spaces.
  defp readable(code), do: code |> String.upcase() |> String.replace(~r/[\s-]/, "")

  defp new_code do
    # Only bytes below 248, a whole multiple of the 31 letters, so every
    # letter is as likely as every other.
    picked =
      32
      |> :crypto.strong_rand_bytes()
      |> :binary.bin_to_list()
      |> Enum.filter(&(&1 < 248))
      |> Enum.take(@length)

    if length(picked) == @length,
      do: Enum.map(picked, &Enum.at(@alphabet, rem(&1, 31))) |> List.to_string(),
      else: new_code()
  end

  defp written(code), do: String.slice(code, 0, 5) <> "-" <> String.slice(code, 5, 5)

  defp sha256(code), do: :sha256 |> :crypto.hash(code) |> Base.encode16(case: :lower)
end
