defmodule PatchbayWeb.Plugs.CurrentProfile do
  @moduledoc """
  The one place a request turns its cookie into a signed-in profile, as
  ash-template's `enforce_authority/1`.

  The signed session cookie carries a sign-in lineage and nothing else
  (`Patchbay.Accounts.SessionAuthority`): no cookie, header, parameter or body
  names a profile, so a request cannot sign itself in as somebody else. The
  profile comes from the lineage's row, and only while the claim is exactly
  current, its sign-in is under 30 days old, its profile may act
  (`Patchbay.Identity.AgentProfile.may_act?/1`) and no suspension came after
  it. Anything else leaves the request signed out.

  It assigns `current_profile`, `current_lineage` (the lineage of a current
  claim, signed in or not), `session_refused` (the cookie states a claim that
  is not current, which no ordinary response may replace, so the page says so
  and the browser retires it through `PatchbayWeb.PrivySessionController`) and
  `signed_out_reason`: `:expired` when the cookie names a sign-in that has
  ended, `:signed_out` when it names none, nil when signed in.

  A profile the database is too busy to read is never taken for one that is
  gone: the page answers busy, and the sign-in still holds when it is opened
  again.
  """

  @behaviour Plug

  import Plug.Conn

  alias Patchbay.Accounts.SessionAuthority

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    session = get_session(conn)

    {lineage, profile, lapses_at} =
      session |> SessionAuthority.claim() |> SessionAuthority.resolve()

    refused? = is_nil(lineage) and SessionAuthority.claim_shaped?(session)

    merge_assigns(conn,
      current_lineage: lineage,
      current_profile: profile,
      session_refused: refused?,
      signed_out_reason: signed_out_reason(profile, refused? or not is_nil(lapses_at))
    )
  end

  @doc """
  Why a request or page holds no profile: `:expired` when its cookie named a
  sign-in that has ended, `:signed_out` when it named none, nil when it holds
  one.
  """
  @spec signed_out_reason(struct() | nil, boolean()) :: :expired | :signed_out | nil
  def signed_out_reason(nil, true), do: :expired
  def signed_out_reason(nil, false), do: :signed_out
  def signed_out_reason(_profile, _ended?), do: nil
end
