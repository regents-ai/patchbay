defmodule Patchbay.OAuth do
  @moduledoc "Scoped account consent through Patchbay's existing Privy profiles."
  @behaviour RegentOAuth

  alias Patchbay.Identity.AgentProfile

  def config, do: Application.fetch_env!(:patchbay, __MODULE__)
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
  Disconnects every app connected to `profile`'s person, ending each app's
  access and refresh tokens (`RegentOAuth.revoke_client/2`), so an app the
  person connected before a suspension stays disconnected after it is lifted.
  A wallet author connects no apps. While connected apps are switched off
  their tokens can be neither used nor refreshed, and there is nothing to
  reach.
  """
  @spec disconnect_apps(AgentProfile.t()) :: :ok
  def disconnect_apps(%{authentication_origin: :privy, privy_user_id: subject}) do
    if RegentOAuth.enabled?() do
      subject
      |> RegentOAuth.connected_clients()
      |> Enum.each(fn %{id: client_id} ->
        {:ok, :ok} = RegentOAuth.revoke_client(subject, client_id)
      end)
    end

    :ok
  end

  def disconnect_apps(%{authentication_origin: :wallet}), do: :ok
end
