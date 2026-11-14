defmodule Patchbay.OAuth do
  @moduledoc """
  Scoped account consent through Patchbay's existing Privy profiles, one sign-in
  for each of Patchbay's two addresses (`PatchbayWeb.SiteEdition`):

    * `:open`, the ChatGPT plugin's, for `/chatgpt/mcp` at the open address;
    * `:main`, every other connected app's, such as Claude's connector, for
      `/mcp` at patchbay.help.

  Each is its own issuer for its own MCP address. `config/0` is the settings of
  the address the calling process serves, which the endpoint and each LiveView
  keep for it (`PatchbayWeb.SiteEdition.current/0`), so every code and token is
  issued, written with and checked against that address's issuer and resource
  (`RegentOAuth.bind/1`, `RegentOAuth.bound?/1`): a token one address issued is
  refused at the other. Work outside a request that asks the provider about a
  token names its address first (`Patchbay.OAuth.Actor.delivery_authorized?/1`).
  """
  @behaviour RegentOAuth

  alias Patchbay.Identity.AgentProfile
  alias PatchbayWeb.SiteEdition

  @doc "The sign-in settings of the address this process serves."
  def config, do: config(SiteEdition.current())

  @doc "The sign-in settings of `edition`'s address."
  def config(edition),
    do: :patchbay |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(edition)

  @doc """
  Checks each address's settings with the provider as a boot starts, and the
  hosted identities' (`RegentMCPAgents.configure!/0`) against the open
  address's, which they need switched on.
  """
  @spec configure!() :: :ok
  def configure! do
    for edition <- [:main, :open],
        do: :ok = SiteEdition.within(edition, fn -> RegentOAuth.configure(__MODULE__) end)

    SiteEdition.within(:open, &RegentMCPAgents.configure!/0)
  end

  def repo, do: Patchbay.Repo

  def current_subject(conn) do
    case conn.assigns[:current_profile] do
      %{authentication_origin: :privy, privy_user_id: subject} = profile ->
        if AgentProfile.may_act?(profile), do: subject

      _ ->
        nil
    end
  end

  def profile(subject) when is_binary(subject) do
    case Patchbay.Identity.get_profile_by_privy_user_id(subject) do
      {:ok, %{authentication_origin: :privy} = profile} ->
        if AgentProfile.may_act?(profile), do: profile

      {:ok, _} ->
        nil

      {:error, error} ->
        raise error
    end
  end

  def active_subject?(subject), do: not is_nil(profile(subject))

  @doc """
  Disconnects every app connected to `profile`'s person, at both addresses,
  ending each app's access and refresh tokens (`RegentOAuth.revoke_client/2`),
  so an app the person connected before a suspension stays disconnected after
  it is lifted. Only `Patchbay.Identity.DisconnectApps` calls it, whose queue
  runs only at a boot with connected apps switched on. An app counts as
  connected once it holds a token; an authorization code not yet exchanged is
  not listed.
  """
  @spec disconnect_apps(AgentProfile.t()) :: :ok
  def disconnect_apps(%{authentication_origin: :privy, privy_user_id: subject}) do
    subject
    |> RegentOAuth.connected_clients()
    |> Enum.each(fn %{id: client_id} ->
      {:ok, :ok} = RegentOAuth.revoke_client(subject, client_id)
    end)
  end

  @doc """
  Disconnects one of the apps connected to `subject`'s account, at either
  address. `client_id` comes from the page, so only an app this account has
  connected is disconnected; any other id is `:not_connected`.
  """
  @spec disconnect_app(String.t(), String.t()) :: {:ok, String.t()} | {:error, :not_connected}
  def disconnect_app(subject, client_id) when is_binary(subject) and is_binary(client_id) do
    case Enum.find(RegentOAuth.connected_clients(subject), &(&1.id == client_id)) do
      %{name: name} ->
        {:ok, :ok} = RegentOAuth.revoke_client(subject, client_id)
        {:ok, name}

      nil ->
        {:error, :not_connected}
    end
  end
end
