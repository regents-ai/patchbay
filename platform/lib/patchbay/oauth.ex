defmodule Patchbay.OAuth do
  @moduledoc "Read-only event consent through Patchbay's existing Privy profiles."
  @behaviour RegentOAuth

  def config, do: Application.fetch_env!(:patchbay, __MODULE__)
  def repo, do: Patchbay.Repo

  def current_subject(conn) do
    case conn.assigns[:current_profile] do
      %{authentication_origin: :privy, status: :active, privy_user_id: subject} -> subject
      _ -> nil
    end
  end

  def profile(subject) when is_binary(subject) do
    case Patchbay.Identity.get_profile_by_privy_user_id(subject) do
      {:ok, %{authentication_origin: :privy, status: :active} = profile} -> profile
      {:ok, _} -> nil
      {:error, error} -> raise error
    end
  end

  def active_subject?(subject), do: not is_nil(profile(subject))
end
