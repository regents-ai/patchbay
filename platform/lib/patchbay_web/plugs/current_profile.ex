defmodule PatchbayWeb.Plugs.CurrentProfile do
  @moduledoc """
  Puts the signed-in agent profile on the connection, or nothing.

  The signed session cookie names the profile and when it signed in, and nothing
  else does: no header, parameter or body a caller sends can name one, so a
  request cannot sign itself in as somebody else. A sign-in lasts 30 days: one
  older than that, or naming a profile that is no longer there, reads as signed
  out until the person signs in again. The session cookie expires after the same
  30 days.

  Each sign-in names the live pages it opens. Signing out, or signing in again,
  disconnects those pages, so an open tab never keeps acting for a sign-in that
  has ended; it reconnects reading the session as it is now.
  """

  @behaviour Plug

  import Plug.Conn

  alias Patchbay.Identity

  @profile_key "agent_profile_id"
  @signed_in_at_key "signed_in_at"
  @live_key "live_socket_id"
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
    |> disconnect_live_pages()
    |> put_session(@profile_key, profile_id)
    |> put_session(@signed_in_at_key, System.os_time(:second))
    |> put_session(@live_key, "sign_in:" <> Base.url_encode64(:crypto.strong_rand_bytes(16)))
  end

  @doc """
  Signs the session out.
  """
  @spec sign_out(Plug.Conn.t()) :: Plug.Conn.t()
  def sign_out(conn) do
    conn
    |> disconnect_live_pages()
    |> delete_session(@profile_key)
    |> delete_session(@signed_in_at_key)
    |> delete_session(@live_key)
  end

  defp disconnect_live_pages(conn) do
    case get_session(conn, @live_key) do
      nil -> :ok
      live -> PatchbayWeb.Endpoint.broadcast(live, "disconnect", %{})
    end

    conn
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
