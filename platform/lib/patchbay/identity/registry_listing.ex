defmodule Patchbay.Identity.RegistryListing do
  @moduledoc """
  A wallet's public page in the Base agent registry, when its agent listed
  itself there through the sign-in service. The sign-in service keeps the
  listing and names it in its activity answer; Patchbay reads it when a
  profile's page is drawn and stores nothing.
  """

  @type url :: String.t() | nil

  @doc "The wallet's registry page, or nil when it has none."
  @spec url(String.t()) :: {:ok, url()} | {:error, term()}
  def url(wallet_address) when is_binary(wallet_address) do
    with {:ok, config} <- config(),
         {:ok, %Req.Response{status: 200, body: %{"data" => %{"agentRegistration" => listing}}}} <-
           Req.post(
             config.base_url <> "/api/shared/siwa/activity",
             options(config, wallet_address)
           ) do
      registry_url(listing)
    else
      {:ok, %Req.Response{status: 200}} -> {:error, :unexpected_answer}
      {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp registry_url(nil), do: {:ok, nil}
  defp registry_url(%{"registryUrl" => "https://" <> _rest = url}), do: {:ok, url}
  defp registry_url(_listing), do: {:error, :unexpected_listing}

  defp config do
    config = Application.get_env(:patchbay, :siwa_activity, [])

    case {config[:base_url], config[:read_token]} do
      {"http" <> _rest = base_url, token} when is_binary(token) and token != "" ->
        {:ok, %{base_url: String.trim_trailing(base_url, "/"), token: token}}

      _missing ->
        {:error, :not_configured}
    end
  end

  # The listing is all Patchbay wants, so the activity window starts now.
  defp options(config, wallet_address) do
    [retry: false, receive_timeout: 2_000, connect_options: [timeout: 1_000]]
    |> Keyword.merge(Application.get_env(:patchbay, :siwa_activity_req_options, []))
    |> Keyword.merge(
      auth: {:bearer, config.token},
      json: %{wallet_address: wallet_address, since: DateTime.to_iso8601(DateTime.utc_now())}
    )
  end
end
