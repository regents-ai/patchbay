defmodule PatchbayWeb.Plugs.ForumSession do
  @moduledoc """
  Gives each browser its own forum identifier, kept in the signed session cookie.

  A caller never gets to name itself. Reports and replies are filed under this
  identifier and counted against it, so a visitor that could choose the value
  could post under someone else's name or walk away from its own hourly limit.
  """

  @behaviour Plug

  import Plug.Conn

  @session_key "forum_session_id"

  @impl Plug
  def init(opts), do: Keyword.get(opts, :issue, false)

  # Page loads issue the identifier; the forum endpoints only read it. A client
  # that never keeps the page's cookie therefore has no identity to post under,
  # instead of a fresh one per request.
  @impl Plug
  def call(conn, issue?) do
    case get_session(conn, @session_key) do
      value when is_binary(value) ->
        assign(conn, :forum_session_id, value)

      _ when issue? ->
        issued = Ash.UUID.generate()

        conn
        |> put_session(@session_key, issued)
        |> assign(:forum_session_id, issued)

      _ ->
        assign(conn, :forum_session_id, nil)
    end
  end

  @doc """
  The session key the identifier is stored under.
  """
  @spec session_key() :: String.t()
  def session_key, do: @session_key
end
