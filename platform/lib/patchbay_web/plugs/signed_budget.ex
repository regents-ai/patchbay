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
  every Regent site. The hosted MCP server counts the same share with
  `count/1` and answers a refusal in JSON-RPC itself.
  """

  @behaviour Plug

  alias PatchbayWeb.ClientAddress
  alias PatchbayWeb.ReadLimit
  alias RegentAgentAccess.RateLimit

  @default_signed_per_minute 120
  @policy "signed"
  @window 60

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    RateLimit.call(
      conn,
      RateLimit.init(
        policy: @policy,
        limit: signed_per_minute(),
        window: @window,
        admit: &ReadLimit.admit/3,
        key: &ClientAddress.key/1
      )
    )
  end

  @doc """
  Counts `conn` against its address's signed share, as `call/2` does, and
  adds the rate-limit headers, without answering: `{:rate_limited, conn,
  seconds}` names the seconds until the share has room again.
  """
  @spec count(Plug.Conn.t()) ::
          {:ok, Plug.Conn.t()} | {:rate_limited, Plug.Conn.t(), pos_integer()}
  def count(conn) do
    case ReadLimit.admit({@policy, ClientAddress.key(conn)}, signed_per_minute(), @window) do
      {:ok, budget} ->
        {:ok, RateLimit.put_headers(conn, @policy, budget)}

      {:error, :rate_limited, budget} ->
        {:rate_limited, RateLimit.put_headers(conn, @policy, budget), budget.reset}
    end
  end

  defp signed_per_minute do
    Application.get_env(:patchbay, :signed_per_minute, @default_signed_per_minute)
  end
end
