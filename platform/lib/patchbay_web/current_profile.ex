defmodule PatchbayWeb.CurrentProfile do
  @moduledoc """
  Gives every live view the same `@current_profile` and `@signed_out_reason` a
  plain page gets, as ash-template's `Live.Session` does.

  The first render belongs to the request whose plug has just read the claim
  (`PatchbayWeb.Plugs.CurrentProfile`), so it takes that answer. A connected
  page reads the claim from the cookie its own socket connected with, which
  LiveView hands the mount under the keys of the page's signed token. That
  token never carries a claim: it only says which lineage the page was drawn
  for (`render_context/1`). A claim that is not current connects signed out,
  and a page drawn for another lineage is loaded again from its address.

  A signed-in page holds a lease, its lineage and profile, rather than the
  claim, because signing in again on another tab advances the claim beneath an
  open page. The lease is read again before every navigation, event, message
  and background result reaches the page, because a page can stay open past
  the sign-in's lifetime or its profile's suspension, and what the page
  unlocked when it opened (the account's own controls, a paid fix) must end
  with it. While it holds, the page goes on with the profile as it reads now.
  Once it has lapsed, the navigation, event, message or result is dropped. A
  navigation then goes to the front page. The rest send `:default` pages to
  the front too, which ends their process and every subscription and read
  they held; an `:account` page instead drops the profile and says the sign-in
  ended, as the Regent template does. A profile the database is too busy to
  read is not a lapsed sign-in: the check raises, the page's process ends as
  on any fault, and the page reconnects still signed in.

  A signed-in page holds its lease as `session_lease`, nil when no one is
  signed in, and passes it to each component that acts
  (`check_component_lease/2`).
  """

  import Phoenix.Component, only: [assign: 2, assign: 3, assign_new: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, redirect: 2]

  alias Patchbay.Accounts.SessionAuthority
  alias PatchbayWeb.Plugs.CurrentProfile
  alias PatchbayWeb.VisitLog

  @public_root "/"

  @doc """
  What the render knew, signed into the page's LiveView token: the visit
  (`PatchbayWeb.VisitLog.session/1`), the lineage-stable topic of the claim the
  page was drawn for, which names the browser session without being able to
  sign in as it, and the page's address, because a connected mount cannot
  otherwise learn it before `handle_params`, which is too late to refuse the
  mount. LiveView merges these keys over the handshake session, so they can
  never stand in for the sign-in the socket connected with.
  """
  def render_context(conn) do
    conn
    |> VisitLog.session()
    |> Map.merge(rendered_topic(conn.assigns.current_lineage))
    |> Map.put("render_route", local_route(conn.request_path, conn.query_string))
  end

  def on_mount(mode, _params, session, socket) when mode in [:default, :account] do
    if connected?(socket) do
      connected(socket, session, lapsed(mode))
    else
      {:cont,
       socket
       |> assign_new(:current_profile, fn -> nil end)
       |> assign_new(:signed_out_reason, fn -> :signed_out end)
       |> assign(:session_lease, nil)}
    end
  end

  @doc """
  The profile a connected page's own socket signs in, from the `session` its
  mount was given, and the lease that reads it again (`leased_profile/1`), or
  `{nil, nil}`: for a page that reads the sign-in again at each of its own
  presses rather than through `on_mount/4`.
  """
  def connect_lease(session) do
    case session |> SessionAuthority.claim() |> SessionAuthority.resolve() do
      {lineage, %{} = profile, _lapses_at} -> {profile, lease(lineage, profile)}
      _signed_out -> {nil, nil}
    end
  end

  @doc "The profile a lease still signs in, or nil once it has lapsed or when there is none."
  def leased_profile(nil), do: nil

  def leased_profile(%{lineage: lineage, profile_id: profile_id}),
    do: SessionAuthority.leased_profile(lineage, profile_id)

  @doc """
  A LiveComponent's events and background results never reach the page's own
  hooks, so every component that acts calls this from `mount/1`, and its page
  passes it the page's `session_lease` as `lease`. Each event and each result
  first re-reads that lease, as the page does for its own. A current lease
  hands `take_profile`, the component's own function (the one its `update/2`
  uses too), the profile as it reads now. A lapsed lease refuses the event with
  an empty reply, or drops the result unseen, and tells the page, which checks
  its own. A page with no one signed in passes a nil lease and the component
  acts on what the page gave it.
  """
  def check_component_lease(socket, take_profile) do
    socket
    |> attach_hook(:current_profile_event, :handle_event, fn _event, _params, socket ->
      case component_profile(socket) do
        :lapsed -> {:halt, %{}, socket}
        profile -> {:cont, take(socket, take_profile, profile)}
      end
    end)
    |> attach_hook(:current_profile_async, :handle_async, fn _name, _result, socket ->
      case component_profile(socket) do
        :lapsed -> {:halt, socket}
        profile -> {:cont, take(socket, take_profile, profile)}
      end
    end)
  end

  defp component_profile(%{assigns: %{lease: nil}}), do: :signed_out

  defp component_profile(%{assigns: %{lease: lease}}) do
    case leased_profile(lease) do
      nil ->
        send(self(), {__MODULE__, :component_lease_lapsed})
        :lapsed

      profile ->
        profile
    end
  end

  defp take(socket, _take_profile, :signed_out), do: socket
  defp take(socket, take_profile, profile), do: take_profile.(socket, profile)

  # The cookie the socket connected with is the only authority. A claim that is
  # not current connects signed out, saying the sign-in ended; a current one
  # drives the socket when the page was drawn for its lineage, and otherwise
  # one full request for the same address realigns them.
  defp connected(socket, session, lapsed) do
    case SessionAuthority.claim(session) do
      nil -> {:cont, signed_out(socket, SessionAuthority.claim_shaped?(session))}
      claim -> admit(socket, session, claim, lapsed)
    end
  end

  defp admit(socket, session, %{lineage: lineage} = claim, lapsed) do
    case SessionAuthority.resolve(claim) do
      {nil, nil, nil} ->
        {:cont, signed_out(socket, true)}

      {^lineage, profile, lapses_at} ->
        if session["render_topic"] == SessionAuthority.topic(lineage),
          do: {:cont, hold(socket, lineage, profile, lapses_at, lapsed)},
          else: {:halt, redirect(socket, to: session["render_route"])}
    end
  end

  defp hold(socket, _lineage, nil, lapses_at, _lapsed),
    do: signed_out(socket, not is_nil(lapses_at))

  defp hold(socket, lineage, profile, _lapses_at, lapsed) do
    lease = lease(lineage, profile)

    socket
    |> assign(current_profile: profile, signed_out_reason: nil, session_lease: lease)
    |> recheck_navigation(lease)
    |> attach_hook(:current_profile_event, :handle_event, fn _event, _params, socket ->
      recheck(socket, lease, lapsed)
    end)
    |> attach_hook(:current_profile_info, :handle_info, fn
      {__MODULE__, :component_lease_lapsed}, socket ->
        {_cont_or_halt, socket} = recheck(socket, lease, lapsed)
        {:halt, socket}

      _message, socket ->
        recheck(socket, lease, lapsed)
    end)
    |> attach_hook(:current_profile_async, :handle_async, fn _name, _result, socket ->
      recheck(socket, lease, lapsed)
    end)
  end

  defp signed_out(socket, ended?) do
    assign(socket,
      current_profile: nil,
      signed_out_reason: CurrentProfile.signed_out_reason(nil, ended?),
      session_lease: nil
    )
  end

  defp lease(lineage, profile), do: %{lineage: lineage, profile_id: profile.id}

  defp lapsed(:default), do: &redirect(&1, to: @public_root)
  defp lapsed(:account), do: & &1

  # The nested account header has no router and receives no handle_params.
  defp recheck_navigation(%{router: nil} = socket, _lease), do: socket

  # LiveView calls `handle_params` straight after the connected mount, for the
  # address the page opened on. The mount has just read the lease, so that call
  # takes the mount's answer; every navigation after it reads the lease again.
  defp recheck_navigation(socket, lease) do
    socket
    |> assign(initial_params?: true)
    |> attach_hook(:current_profile_params, :handle_params, fn
      _params, _uri, %{assigns: %{initial_params?: true}} = socket ->
        {:cont, assign(socket, initial_params?: false)}

      _params, _uri, socket ->
        recheck(socket, lease, &redirect(&1, to: @public_root))
    end)
  end

  defp recheck(socket, lease, lapsed) do
    case leased_profile(lease) do
      nil ->
        {:halt, socket |> assign(current_profile: nil, signed_out_reason: :expired) |> lapsed.()}

      profile ->
        {:cont, assign(socket, :current_profile, profile)}
    end
  end

  defp rendered_topic(nil), do: %{}
  defp rendered_topic(lineage), do: %{"render_topic" => SessionAuthority.topic(lineage)}

  defp local_route(path, ""), do: path
  defp local_route(path, query), do: path <> "?" <> query
end
