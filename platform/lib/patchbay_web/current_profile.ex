defmodule PatchbayWeb.CurrentProfile do
  @moduledoc """
  Gives every live view the same `@current_profile` a plain page gets.

  A live view reads the session it was mounted with rather than the connection,
  so the profile is looked up here from the same signed key the plug reads.

  A signed-in page is checked again before every navigation, event, message and
  background result reaches it, because a page can stay open past the sign-in's
  lifetime, and what the page unlocked when it opened (a room owner's controls,
  a paid fix) must end with it. The same check the plug makes is run on the
  session the page was mounted with: while it still holds, the page goes on
  with the profile as it reads now; once it has lapsed, the navigation, event,
  message or result is dropped and the page is sent to the front, which ends
  its process and every subscription and read it held.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, redirect: 2]

  alias PatchbayWeb.Plugs.CurrentProfile

  @public_root "/"

  def on_mount(:default, _params, session, socket) do
    socket = assign(socket, :current_profile, CurrentProfile.signed_in_profile(session))
    {:cont, hold(socket, session)}
  end

  defp hold(%{assigns: %{current_profile: nil}} = socket, _session), do: socket

  defp hold(socket, session) do
    socket
    |> attach_hook(:current_profile_params, :handle_params, fn _params, _uri, socket ->
      recheck(socket, session)
    end)
    |> attach_hook(:current_profile_event, :handle_event, fn _event, _params, socket ->
      recheck(socket, session)
    end)
    |> attach_hook(:current_profile_info, :handle_info, fn _message, socket ->
      recheck(socket, session)
    end)
    |> attach_hook(:current_profile_async, :handle_async, fn _name, _result, socket ->
      recheck(socket, session)
    end)
  end

  defp recheck(socket, session) do
    case CurrentProfile.signed_in_profile(session) do
      nil -> {:halt, socket |> assign(:current_profile, nil) |> redirect(to: @public_root)}
      profile -> {:cont, assign(socket, :current_profile, profile)}
    end
  end
end
