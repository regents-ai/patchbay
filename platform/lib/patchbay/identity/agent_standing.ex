defmodule Patchbay.Identity.AgentStanding do
  @moduledoc """
  What the sign-in service says in public about a wallet's agent: its page in
  the Base agent registry, when it listed itself there, and whether a person
  backs it through World ID. The service names both in its activity answer;
  Patchbay reads them when a profile's page is drawn and stores nothing.
  """

  @type t :: %{registry_url: String.t() | nil, human_backed?: boolean()}

  @doc "The wallet's registry page and whether a person backs its agent."
  @spec fetch(String.t()) :: {:ok, t()} | {:error, term()}
  def fetch(wallet_address) when is_binary(wallet_address) do
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
         {:ok, human_backed?} <- human_backed?(book) do
      {:ok, %{registry_url: registry_url, human_backed?: human_backed?}}
    else
      {:ok, %Req.Response{status: 200}} -> {:error, :unexpected_answer}
      {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp registry_url(nil), do: {:ok, nil}
  defp registry_url(%{"registryUrl" => "https://" <> _rest = url}), do: {:ok, url}
  defp registry_url(_listing), do: {:error, :unexpected_listing}

  # The person's World ID number is theirs; Patchbay only says one exists.
  defp human_backed?(nil), do: {:ok, false}

  defp human_backed?(%{"humanId" => human_id}) when is_binary(human_id) do
    if Regex.match?(~r/\A0x[0-9a-fA-F]{64}\z/, human_id),
      do: {:ok, true},
      else: {:error, :unexpected_agent_book}
  end

  defp human_backed?(_book), do: {:error, :unexpected_agent_book}

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
