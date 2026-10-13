defmodule PatchbayWeb.Plugs.SignedBudget do
  @moduledoc """
  Gives each address a share of signed agent requests a minute, counted
  before the sign-in service is asked about the signature, so one caller
  cannot spend that service's time, or Patchbay's turn with it, on requests
  nobody signed.

  It stands first in every router pipeline that checks a signature, so a
  request is counted whether or not it carries one and whatever its method:
  posts, the hello, reading a payment back and the two requests that finish a
  payment. A signed `GET` is a read as well and draws on that share too
  (`PatchbayWeb.Plugs.ReadBudget`). Agents that leave from one shared address
  share the count.

  The counting, the standard `RateLimit-Policy` and `RateLimit` headers for
  the "signed" share and the 429 are `RegentAgentAccess.RateLimit`, as on
  every Regent site.
  """

  @behaviour Plug

  alias PatchbayWeb.ClientAddress
  alias PatchbayWeb.ReadLimit
  alias RegentAgentAccess.RateLimit

  @default_signed_per_minute 120

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    RateLimit.call(
      conn,
      RateLimit.init(
        policy: "signed",
        limit: signed_per_minute(),
        window: 60,
        admit: &ReadLimit.admit/3,
        key: &ClientAddress.key/1
      )
    )
  end

  defp signed_per_minute do
    Application.get_env(:patchbay, :signed_per_minute, @default_signed_per_minute)
  end
end
