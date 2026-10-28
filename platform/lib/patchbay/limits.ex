defmodule Patchbay.Limits do
  @moduledoc """
  The named allowances in `config :patchbay, :limits`, as in ash-template: how
  often one person may save each kind of writing others read, and how often one
  client address may search from a page. Each is spent through
  `PatchbayWeb.ReadLimit`, the counter every other share already uses.
  """

  alias Patchbay.Identity.AgentProfile
  alias PatchbayWeb.ReadLimit

  @doc "Spends one of `name`'s allowance for `who`: `:ok` or `:limited`."
  @spec spend(atom(), term()) :: :ok | :limited
  def spend(name, who) do
    config = :patchbay |> Application.fetch_env!(:limits) |> Keyword.fetch!(name)

    case ReadLimit.admit({name, who}, config[:limit], config[:window_seconds]) do
      {:ok, _budget} -> :ok
      {:error, :rate_limited, _budget} -> :limited
    end
  end

  @doc "Who an actor's writing counts against: the signed-in person."
  @spec writer(AgentProfile.t()) :: {:profile, Ecto.UUID.t()}
  def writer(%AgentProfile{id: id}), do: {:profile, id}
end
