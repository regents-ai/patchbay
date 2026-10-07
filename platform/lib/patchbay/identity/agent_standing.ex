defmodule Patchbay.Identity.AgentStanding do
  @moduledoc """
  What the sign-in service says in public about a profile's agent: its page in
  the Base agent registry, whether a person verified with World ID stands
  behind it, and how many agents that same person stands behind
  (`RegentAgents.HumanBacking`). The service names all of it in its activity
  answer; Patchbay asks for that answer each time a profile is read and stores
  nothing.

  A fresh answer is not a fresh look at World Chain. The service reads the
  wallet's World AgentBook entry when the wallet signs in and answers from that
  saved reading, so the mark is as old as the wallet's latest sign-in: a person
  backing the agent, or no longer backing it, shows once it signs in again.
  """

  require Logger

  alias Patchbay.Identity.AgentProfile
  alias RegentAgents.HumanBacking

  @type t :: %{
          registry_url: String.t() | nil,
          human_backed: boolean(),
          same_person_agent_count: pos_integer() | nil
        }

  # Two states only: a profile whose standing cannot be read now is shown as
  # one no verified person stands behind, never as "checking".
  @unread %{registry_url: nil, human_backed: false, same_person_agent_count: nil}

  @doc "The profile's registry page and the verified person behind its agent, if any."
  @spec for_profile(AgentProfile.t()) :: t()
  def for_profile(%AgentProfile{wallet_address: nil}), do: @unread

  def for_profile(%AgentProfile{} = profile) do
    case fetch(profile.wallet_address) do
      {:ok, standing} ->
        standing

      {:error, reason} ->
        Logger.warning("Agent standing for #{profile.public_id} unread: #{inspect(reason)}")
        @unread
    end
  end

  defp fetch(wallet_address) do
    with {:ok, config} <- config(),
         {:ok,
          %Req.Response{
            status: 200,
            body: %{"data" => %{"agentRegistration" => listing, "agentBook" => book}}
          }} <-
           Req.post(
             config.base_url <> "/api/shared/siwa/activity",
             options(config, wallet_address)
           ),
         {:ok, registry_url} <- registry_url(listing),
         {:ok, backing} <- human_backing(book) do
      {:ok, Map.put(backing, :registry_url, registry_url)}
    else
      {:ok, %Req.Response{status: 200}} -> {:error, :unexpected_answer}
      {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp registry_url(nil), do: {:ok, nil}
  defp registry_url(%{"registryUrl" => "https://" <> _rest = url}), do: {:ok, url}
  defp registry_url(_listing), do: {:error, :unexpected_listing}

  # The person's World ID number is theirs; the shared reader drops it.
  defp human_backing(book) do
    case HumanBacking.read(book) do
      {:ok, backing} -> {:ok, backing}
      :error -> {:error, :unexpected_agent_book}
    end
  end

  defp config do
    config = Application.get_env(:patchbay, :siwa_activity, [])

    case {config[:base_url], config[:read_token]} do
      {"http" <> _rest = base_url, token} when is_binary(token) and token != "" ->
        {:ok, %{base_url: String.trim_trailing(base_url, "/"), token: token}}

      _missing ->
        {:error, :not_configured}
    end
  end

  # Only the agent's standing is wanted, so the activity window starts now.
  defp options(config, wallet_address) do
    [retry: false, receive_timeout: 2_000, connect_options: [timeout: 1_000]]
    |> Keyword.merge(Application.get_env(:patchbay, :siwa_activity_req_options, []))
    |> Keyword.merge(
      auth: {:bearer, config.token},
      json: %{wallet_address: wallet_address, since: DateTime.to_iso8601(DateTime.utc_now())}
    )
  end
end
