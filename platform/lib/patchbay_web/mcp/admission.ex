defmodule PatchbayWeb.MCP.Admission do
  @moduledoc """
  Admits a protected call at `/mcp` exactly as every signed door does: the
  address's signed share is counted first (`PatchbayWeb.Plugs.SignedBudget`),
  then the request's own SIWA signature and the agent's current pairing are
  checked (`PatchbayWeb.Plugs.PairedAgent`). The rules are those plugs'; only
  the answer to a refusal differs. It is JSON-RPC with the request's id
  (`PatchbayWeb.MCP.Refusal`), so the client can show the model the code,
  the words and the hint instead of a failed connection.
  """

  @behaviour Siwa.AgentAuthPlug.Hooks

  import Plug.Conn

  alias PatchbayWeb.MCP.Refusal
  alias PatchbayWeb.Plugs.PairedAgent
  alias PatchbayWeb.Plugs.SignedBudget

  @doc "Admits `conn`'s signed, paired agent, or answers the refusal and halts."
  @spec call(Plug.Conn.t()) :: Plug.Conn.t()
  def call(conn) do
    case SignedBudget.count(conn) do
      {:ok, conn} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> Siwa.AgentAuthPlug.call(PairedAgent.siwa_options(__MODULE__))

      {:rate_limited, conn, seconds} ->
        Refusal.rate_limited(conn, seconds)
    end
  end

  @impl Siwa.AgentAuthPlug.Hooks
  defdelegate before_verify(conn, headers), to: PairedAgent

  @impl Siwa.AgentAuthPlug.Hooks
  defdelegate accept(conn, data, context), to: PairedAgent

  @impl Siwa.AgentAuthPlug.Hooks
  def deny(conn, failure) do
    {status, %{error: error}} = PairedAgent.refusal(failure)
    Refusal.refuse(conn, error, status)
  end
end
