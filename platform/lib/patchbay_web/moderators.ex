defmodule PatchbayWeb.Moderators do
  @moduledoc """
  The door to the live admin pages (`/admin/people`, `/admin/people/:public_id`,
  `/admin/messages`, `/admin/offers`).

  Only a signed-in profile whose verified wallet is on the moderator list
  (`Patchbay.Checks.Moderator`) reaches them; anyone else is answered as
  though the page does not exist. `PatchbayWeb.CurrentProfile` refreshes the
  profile first, and this reads it again before every navigation, press and
  message, so a changed wallet or moderator list also ends the private reads
  an already-open page holds.

  The door only decides who sees a page. Each change a page makes goes
  through its action's own policy.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, redirect: 2]

  alias Patchbay.Checks.Moderator
  alias PatchbayWeb.Forum.NotFoundError

  def on_mount(:default, _params, _session, socket) do
    if !Moderator.moderator?(socket.assigns.current_profile), do: raise(NotFoundError)

    {:cont,
     socket
     |> check_navigation()
     |> attach_hook(:moderator_authority, :handle_event, fn _event, _params, socket ->
       check(socket)
     end)
     |> attach_hook(:moderator_authority, :handle_info, fn _message, socket ->
       check(socket)
     end)}
  end

  # The account header nested in the page has no router and receives no
  # handle_params.
  defp check_navigation(%{router: nil} = socket), do: socket

  defp check_navigation(socket) do
    attach_hook(socket, :moderator_authority, :handle_params, fn _params, _uri, socket ->
      check(socket)
    end)
  end

  defp check(socket) do
    if Moderator.moderator?(socket.assigns.current_profile),
      do: {:cont, socket},
      else: {:halt, redirect(socket, to: "/")}
  end
end
