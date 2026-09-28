defmodule PatchbayWeb.Plugs.CurrentProfile do
  @moduledoc """
  Puts the signed-in agent profile on the connection, or nothing.

  The signed session cookie names the profile and when it signed in, and nothing
  else does: no header, parameter or body a caller sends can name one, so a
  request cannot sign itself in as somebody else. A sign-in lasts 30 days: one
  older than that, or naming a profile that is no longer there, reads as signed
  out until the person signs in again. The session cookie expires after the same
  30 days.
  """

  @behaviour Plug

  import Plug.Conn

  alias Patchbay.Identity

  @profile_key "agent_profile_id"
  @signed_in_at_key "signed_in_at"
  @lifetime_seconds Application.compile_env!(:patchbay, :sign_in_lifetime_seconds)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    assign(conn, :current_profile, conn |> get_session() |> signed_in_profile())
  end

  @doc """
  Signs the session in as the profile, from now.
  """
  @spec sign_in(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def sign_in(conn, profile_id) do
    conn
    |> put_session(@profile_key, profile_id)
    |> put_session(@signed_in_at_key, System.os_time(:second))
  end

  @doc """
  Signs the session out.
  """
  @spec sign_out(Plug.Conn.t()) :: Plug.Conn.t()
  def sign_out(conn) do
    conn
    |> delete_session(@profile_key)
    |> delete_session(@signed_in_at_key)
  end

  @doc """
  The profile a session belongs to, read the same way by pages and live views.
  """
  @spec signed_in_profile(map()) :: Patchbay.Identity.AgentProfile.t() | nil
  def signed_in_profile(%{@profile_key => id, @signed_in_at_key => signed_in_at})
      when is_binary(id) and is_integer(signed_in_at) do
    if System.os_time(:second) - signed_in_at < @lifetime_seconds, do: profile(id)
  end

  def signed_in_profile(_session), do: nil

  defp profile(id) do
    case Identity.get_profile(id) do
      {:ok, %{authentication_origin: :privy} = profile} -> profile
      {:ok, _wallet_author} -> nil
      {:error, _gone} -> nil
    end
  end
end
