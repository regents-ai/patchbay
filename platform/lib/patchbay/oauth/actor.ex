defmodule Patchbay.OAuth.Actor do
  @moduledoc "An OAuth event reader, never a paired-agent or wallet authority."
  @enforce_keys [
    :subject,
    :client_id,
    :token_id,
    :expires_at,
    :beneficiary_profile_id,
    :principals
  ]
  defstruct @enforce_keys

  def new(principal, profile) do
    struct!(
      __MODULE__,
      Map.merge(
        Map.take(principal, [:subject, :client_id, :token_id, :expires_at]),
        %{
          beneficiary_profile_id: profile.id,
          principals: [Patchbay.Forum.Principal.for_profile(profile.id)]
        }
      )
    )
  end

  def live?(%__MODULE__{} = actor) do
    RegentOAuth.live_token?(actor.token_id, actor.subject, actor.client_id) and
      match?(
        %{id: id} when id == actor.beneficiary_profile_id,
        Patchbay.OAuth.profile(actor.subject)
      )
  end

  def identity_owner(%__MODULE__{} = actor),
    do: "oauth:" <> actor.client_id <> ":" <> hd(actor.principals)

  def delivery_authorized?(%{
        oauth_token_id: token_id,
        oauth_client_id: client_id,
        beneficiary_profile_id: profile_id
      })
      when is_binary(token_id) and is_binary(client_id) and is_binary(profile_id) do
    case Ash.get(Patchbay.Identity.AgentProfile, profile_id, not_found_error?: false) do
      {:ok, %{authentication_origin: :privy, status: :active, privy_user_id: subject}} ->
        RegentOAuth.live_token?(token_id, subject, client_id)

      {:ok, _} ->
        false

      {:error, error} ->
        raise error
    end
  end

  def delivery_authorized?(_), do: false
end
