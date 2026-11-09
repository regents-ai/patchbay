defmodule PatchbayWeb.Plugs.CurrentProfile do
  @moduledoc """
  Puts the signed-in agent profile on the connection, or nothing.

  The signed session cookie names the profile and when it signed in, and nothing
  else does: no header, parameter or body a caller sends can name one, so a
  request cannot sign itself in as somebody else. A sign-in lasts 30 days: one
  older than that, naming a profile that is no longer there, naming a profile
  that may not act (`Patchbay.Identity.AgentProfile.may_act?/1`), or made no
  later than its profile's suspension, reads as signed out until the person
  signs in again, and says the sign-in ended (`signed_out_reason/1`).
  Reinstating a profile leaves its old sign-ins ended. The session cookie
  expires after the same 30 days.
  A profile the database is too busy to read is never taken for one that is
  gone: the page answers busy, and the sign-in still holds when it is opened
  again.

  Each sign-in names the live pages it opens. Signing out, or signing in again,
  disconnects those pages, so an open tab never keeps acting for a sign-in that
  has ended; it reconnects reading the session as it is now.

  Signing out starts the browser over: the session is renewed and emptied, and
  the browser gets a new forum identity. Whoever signs in next on the same
  browser inherits nothing from the last person: not the threads they asked,
  the sites they followed, or the Jev answers they got.
  """

  @behaviour Plug

  import Plug.Conn

  alias Patchbay.Identity
  alias Patchbay.Identity.AgentProfile
  alias PatchbayWeb.Plugs.ForumSession

  @profile_key "agent_profile_id"
  @signed_in_at_key "signed_in_at"
  @live_key "live_socket_id"
  @lifetime_seconds Application.compile_env!(:patchbay, :sign_in_lifetime_seconds)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    session = get_session(conn)

    case signed_in_profile(session) do
      nil ->
        merge_assigns(conn, current_profile: nil, signed_out_reason: signed_out_reason(session))

      profile ->
        merge_assigns(conn, current_profile: profile, signed_out_reason: nil)
    end
  end

  @doc """
  Signs the session in as the profile, from `signed_in_at` (Unix seconds),
  which the caller takes before it reads the profile's status, so a sign-in
  racing a suspension is ended by it (`after_cutoff?/2`).
  """
  @spec sign_in(Plug.Conn.t(), String.t(), integer()) :: Plug.Conn.t()
  def sign_in(conn, profile_id, signed_in_at) when is_integer(signed_in_at) do
    conn
    |> disconnect_live_pages()
    |> put_session(@profile_key, profile_id)
    |> put_session(@signed_in_at_key, signed_in_at)
    |> put_session(@live_key, "sign_in:" <> Base.url_encode64(:crypto.strong_rand_bytes(16)))
  end

  @doc """
  Signs the session out and gives the browser a new forum identity.
  """
  @spec sign_out(Plug.Conn.t()) :: Plug.Conn.t()
  def sign_out(conn) do
    Plug.CSRFProtection.delete_csrf_token()

    conn
    |> disconnect_live_pages()
    |> configure_session(renew: true)
    |> clear_session()
    |> ForumSession.issue()
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
  @spec signed_in_profile(map()) :: AgentProfile.t() | nil
  def signed_in_profile(%{@profile_key => id, @signed_in_at_key => signed_in_at})
      when is_binary(id) and is_integer(signed_in_at) do
    if System.os_time(:second) - signed_in_at < @lifetime_seconds, do: profile(id, signed_in_at)
  end

  def signed_in_profile(_session), do: nil

  @doc """
  Why a session that `signed_in_profile/1` reads as signed out holds no
  profile: `:expired` when it still names a sign-in, which has then passed its
  lifetime or lost its profile, and `:signed_out` when it names none.
  """
  @spec signed_out_reason(map()) :: :expired | :signed_out
  def signed_out_reason(%{@profile_key => id, @signed_in_at_key => signed_in_at})
      when is_binary(id) and is_integer(signed_in_at),
      do: :expired

  def signed_out_reason(_session), do: :signed_out

  # A profile that is not there, or an id that names none, is an invalid
  # read; any other error is the database's, and the page says so.
  defp profile(id, signed_in_at) do
    case Identity.get_profile(id, load: [:wallet_addresses]) do
      {:ok, %{authentication_origin: :privy} = profile} ->
        if AgentProfile.may_act?(profile) and after_cutoff?(profile, signed_in_at), do: profile

      {:ok, _wallet_author} ->
        nil

      {:error, %Ash.Error.Invalid{}} ->
        nil

      {:error, error} ->
        raise error
    end
  end

  # The cut-off is the second the database's clock is in as the suspension
  # writes the row (`AgentProfile`'s `suspend`). A sign-in's time is taken, to
  # the second, before it reads the profile's status (`PrivySessionController`),
  # and a read that saw the profile active came before the suspension's write:
  # each waits for the other while it holds the row. So the sign-in's second is
  # no later than the cut-off, and ending every sign-in up to the cut-off, its
  # own second included, ends it. This assumes the web machines' clocks and the
  # database's agree to within a second: a web clock running ahead by part of a
  # second could let a sign-in made up to that part of a second before the
  # suspension outlive it. A sign-in after a reinstatement in the cut-off's own
  # second is ended too; signing in again in the next second holds.
  defp after_cutoff?(%{sessions_valid_after: nil}, _signed_in_at), do: true

  defp after_cutoff?(%{sessions_valid_after: cutoff}, signed_in_at),
    do: signed_in_at > DateTime.to_unix(cutoff)
end
