defmodule PatchbayWeb.ErrorsAdmin do
  @moduledoc """
  Keeps the saved errors at /admin/errors, and the weekly answer check's
  download at /admin/ai-answers.csv, for the site's admins: a signed-in
  profile whose Privy account the site's `:admins` setting names
  (config/config.exs). Anyone else gets the site's ordinary not-found page,
  so the page's existence is not shown either.

  As a plug it checks the request's sign-in (`PatchbayWeb.Plugs.CurrentProfile`)
  and sends the page's own content security policy, with a nonce for the one
  style and one script element the error dashboard writes into its page. As an
  `on_mount` hook it checks the sign-in the page connects with, then reads its
  lease again on every navigation and press, the way every other live page does
  (`PatchbayWeb.CurrentProfile`), so a sign-in that ends or lapses cannot keep
  acting on the page.
  """

  @behaviour Plug

  import Phoenix.Component, only: [assign_new: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, redirect: 2]
  import Plug.Conn

  alias PatchbayWeb.ContentSecurityPolicy
  alias PatchbayWeb.CurrentProfile

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if admin?(conn.assigns.current_profile) do
      nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

      conn
      |> assign(:csp_nonce, nonce)
      |> put_resp_header("content-security-policy", ContentSecurityPolicy.errors(nonce))
    else
      raise Phoenix.Router.NoRouteError, conn: conn, router: PatchbayWeb.Router
    end
  end

  def on_mount(:default, _params, session, socket) do
    if connected?(socket), do: connected(socket, session), else: first_render(socket)
  end

  # The first render takes the profile the plug has just read for this request.
  defp first_render(socket) do
    socket = assign_new(socket, :current_profile, fn -> nil end)
    if admin?(socket.assigns.current_profile), do: {:cont, socket}, else: leave(socket)
  end

  defp connected(socket, session) do
    {profile, lease} = CurrentProfile.connect_lease(session)

    if admin?(profile) do
      {:cont,
       socket
       |> attach_hook(:errors_admin_params, :handle_params, fn _params, _uri, socket ->
         recheck(socket, lease)
       end)
       |> attach_hook(:errors_admin_event, :handle_event, fn _event, _params, socket ->
         recheck(socket, lease)
       end)}
    else
      leave(socket)
    end
  end

  defp recheck(socket, lease) do
    if admin?(CurrentProfile.leased_profile(lease)), do: {:cont, socket}, else: leave(socket)
  end

  defp admin?(%{privy_user_id: id}) when is_binary(id),
    do: id in Application.fetch_env!(:patchbay, :admins)

  defp admin?(_signed_out), do: false

  defp leave(socket), do: {:halt, redirect(socket, to: "/")}
end
