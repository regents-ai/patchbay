defmodule PatchbayWeb.ErrorsAdmin do
  @moduledoc """
  Keeps the saved errors at /admin/errors, and the weekly answer check's
  download at /admin/ai-answers.csv, for Credits admins: a signed-in
  profile whose Privy account the Credits `:admins` setting names
  (REGENT_CREDITS_ADMINS). Anyone else gets the site's ordinary not-found page,
  so the page's existence is not shown either.

  As a plug it checks the request and sends the page's own content security
  policy, with a nonce for the one style and one script element the error
  dashboard writes into its page. As an `on_mount` hook it checks the session the page connects with, then reads the sign-in again on every navigation and
  press, the way every other live page does (`PatchbayWeb.CurrentProfile`), so a
  sign-in that ends or lapses cannot keep acting on the page.
  """

  @behaviour Plug

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, get_connect_info: 2, redirect: 2]
  import Plug.Conn

  alias PatchbayWeb.ContentSecurityPolicy
  alias PatchbayWeb.Plugs.CurrentProfile

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if conn |> get_session() |> admin?() do
      nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

      conn
      |> assign(:csp_nonce, nonce)
      |> put_resp_header("content-security-policy", ContentSecurityPolicy.errors(nonce))
    else
      raise Phoenix.Router.NoRouteError, conn: conn, router: PatchbayWeb.Router
    end
  end

  def on_mount(:default, _params, session, socket) do
    session = if connected?(socket), do: get_connect_info(socket, :session), else: session

    if admin?(session) do
      {:cont,
       socket
       |> attach_hook(:errors_admin_params, :handle_params, fn _params, _uri, socket ->
         recheck(socket, session)
       end)
       |> attach_hook(:errors_admin_event, :handle_event, fn _event, _params, socket ->
         recheck(socket, session)
       end)}
    else
      leave(socket)
    end
  end

  defp recheck(socket, session), do: if(admin?(session), do: {:cont, socket}, else: leave(socket))

  defp admin?(session) do
    case CurrentProfile.signed_in_profile(session) do
      %{privy_user_id: id} when is_binary(id) ->
        id in Application.fetch_env!(:regent_credits, :admins)

      _signed_out ->
        false
    end
  end

  defp leave(socket), do: {:halt, redirect(socket, to: "/")}
end
