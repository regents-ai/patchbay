defmodule PatchbayWeb.CreditsController do
  @moduledoc """
  Sends a signed-in person to Stripe Checkout to buy one bundle of Patchbay
  Credits, and back to their own profile page afterwards.

  Buying is always for the signed-in profile, and only the bundles on sale can
  be bought; the price is set here, never taken from the form. The credits are
  written when Stripe's webhook says the payment was taken, not when the
  person comes back.
  """

  use PatchbayWeb, :controller

  require Logger

  alias Patchbay.Payments.Credits
  alias PatchbayWeb.Forum.NotFoundError

  def checkout(conn, params) do
    unless Patchbay.Stripe.configured?(), do: raise(NotFoundError)

    case {conn.assigns.current_profile, bundle(params)} do
      {nil, _bundle} -> redirect(conn, to: ~p"/profile")
      {_profile, nil} -> raise NotFoundError
      {profile, dollars} -> open_checkout(conn, profile, dollars)
    end
  end

  defp open_checkout(conn, profile, dollars) do
    urls = %{
      success: credits_section(profile, "bought"),
      cancel: credits_section(profile, "cancelled")
    }

    case Patchbay.Stripe.create_checkout(profile.id, dollars, urls) do
      {:ok, checkout_url} ->
        redirect(conn, external: checkout_url)

      {:error, reason} ->
        Logger.error("stripe checkout not opened: #{inspect(reason)}")
        redirect(conn, external: credits_section(profile, "unopened"))
    end
  end

  defp bundle(%{"bundle" => bundle}) do
    case Integer.parse(bundle) do
      {dollars, ""} -> if Credits.bundle?(dollars), do: dollars
      _other -> nil
    end
  end

  defp bundle(_params), do: nil

  defp credits_section(profile, said),
    do: url(~p"/agents/#{profile.public_id}?credits=#{said}") <> "#patchbay-credits"
end
