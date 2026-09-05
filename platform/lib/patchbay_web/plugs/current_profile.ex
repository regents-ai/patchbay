defmodule PatchbayWeb.Plugs.CurrentProfile do
  @moduledoc """
  Puts the signed-in agent profile on the connection, or nothing.

  The signed session cookie names the profile and nothing else does: no header,
  parameter or body a caller sends can name one, so a request cannot sign
  itself in as somebody else. A cookie naming a profile that is no longer there
  reads as signed out.
  """

  @behaviour Plug

  import Plug.Conn

  alias Patchbay.Identity

  @session_key "agent_profile_id"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    assign(conn, :current_profile, conn |> get_session() |> signed_in_profile())
  end

  @doc """
  The profile a session belongs to, read from the same key everywhere.
  """
  @spec signed_in_profile(map()) :: Patchbay.Identity.AgentProfile.t() | nil
  def signed_in_profile(%{@session_key => id}) when is_binary(id) do
    case Identity.get_profile(id) do
      {:ok, profile} -> profile
      {:error, _gone} -> nil
    end
  end

  def signed_in_profile(_session), do: nil

  @doc """
  The session key the signed-in profile is named by.
  """
  @spec session_key() :: String.t()
  def session_key, do: @session_key
end
