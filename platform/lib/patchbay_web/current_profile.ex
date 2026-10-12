defmodule PatchbayWeb.CurrentProfile do
  @moduledoc """
  Gives every live view the same `@current_profile` and `@signed_out_reason` a
  plain page gets.

  A live view reads the session it was mounted with rather than the connection,
  so the profile is looked up here from the same signed key the plug reads.

  A signed-in page is checked again before every navigation, event, message and
  background result reaches it, because a page can stay open past the sign-in's
  lifetime, and what the page unlocked when it opened (a room owner's controls,
  a paid fix) must end with it. The same check the plug makes is run on the
  session the page was mounted with: while it still holds, the page goes on
  with the profile as it reads now. Once it has lapsed, the navigation, event,
  message or result is dropped. A navigation then goes to the front page. The
  rest send `:default` pages to the front too, which ends their process and
  every subscription and read they held; an `:account` page instead drops the
  profile and says the sign-in ended, as the Regent template does.

  A signed-in page holds its claim as `session_lease`, nil when no one is signed
  in, and passes it to each component that acts (`check_component_lease/2`).
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, put_private: 3, redirect: 2]

  alias PatchbayWeb.Plugs.CurrentProfile

  @public_root "/"

  def on_mount(mode, _params, session, socket) when mode in [:default, :account] do
    claim = Map.take(session, ["agent_profile_id", "signed_in_at"])

    socket =
      case CurrentProfile.signed_in_profile(claim) do
        nil ->
          assign(socket,
            current_profile: nil,
            signed_out_reason: CurrentProfile.signed_out_reason(claim)
          )

        profile ->
          assign(socket, current_profile: profile, signed_out_reason: nil)
      end

    {:cont, socket |> assign(:session_lease, lease(socket, claim)) |> hold(claim, lapsed(mode))}
  end

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
    case CurrentProfile.signed_in_profile(lease) do
      nil ->
        send(self(), {__MODULE__, :component_lease_lapsed})
        :lapsed

      profile ->
        profile
    end
  end

  defp take(socket, _take_profile, :signed_out), do: socket
  defp take(socket, take_profile, profile), do: take_profile.(socket, profile)

  defp lease(%{assigns: %{current_profile: nil}}, _claim), do: nil
  defp lease(_socket, claim), do: claim

  defp lapsed(:default), do: &redirect(&1, to: @public_root)
  defp lapsed(:account), do: & &1

  defp hold(%{assigns: %{current_profile: nil}} = socket, _claim, _lapsed), do: socket
  defp hold(%{private: %{current_profile_hooks: true}} = socket, _claim, _lapsed), do: socket

  defp hold(socket, claim, lapsed) do
    socket
    |> check_navigation(claim)
    |> attach_hook(:current_profile_event, :handle_event, fn _event, _params, socket ->
      recheck(socket, claim, lapsed)
    end)
    |> attach_hook(:current_profile_info, :handle_info, fn
      {__MODULE__, :component_lease_lapsed}, socket ->
        {_cont_or_halt, socket} = recheck(socket, claim, lapsed)
        {:halt, socket}

      _message, socket ->
        recheck(socket, claim, lapsed)
    end)
    |> attach_hook(:current_profile_async, :handle_async, fn _name, _result, socket ->
      recheck(socket, claim, lapsed)
    end)
    |> put_private(:current_profile_hooks, true)
  end

  # The nested Credits header has no router and receives no handle_params.
  defp check_navigation(%{router: nil} = socket, _claim), do: socket

  defp check_navigation(socket, claim) do
    attach_hook(socket, :current_profile_params, :handle_params, fn _params, _uri, socket ->
      recheck(socket, claim, &redirect(&1, to: @public_root))
    end)
  end

  defp recheck(socket, claim, lapsed) do
    case CurrentProfile.signed_in_profile(claim) do
      nil ->
        {:halt, socket |> assign(current_profile: nil, signed_out_reason: :expired) |> lapsed.()}

      profile ->
        {:cont, assign(socket, :current_profile, profile)}
    end
  end
end
