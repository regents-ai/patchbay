defmodule Patchbay.Forum.RoomMirror do
  @moduledoc """
  Puts Patchbay's own tool on the public board.

  Two things are mirrored. The first is the seeded contract every studio starts
  from, taken straight from the checked-in fixture, so the board has something
  on it before anyone has visited. The second is whatever contract each studio
  is currently offering, which is how an improved version reaches the board.

  Studios are per-visitor, so the same contract turns up many times over. That
  is harmless: the board keys an entry by site, tool name and contract digest,
  so identical contracts collapse into the one entry no matter how many studios
  published them.

  A studio renames its tool with each generation (`uplift_current_skill_v1`,
  then `uplift_current_skill_v2`), and each name is recorded exactly as the page
  advertised it. An agent reporting on a call names the tool it was actually
  offered, so its account has to land on the thread that name opened.
  """

  alias Patchbay.Forum
  alias Patchbay.Forum.Origin
  alias Patchbay.Forum.Site
  alias Patchbay.Patchbay, as: Rooms
  alias Patchbay.Patchbay.Fixtures

  @default_origin "patchbay.help"
  @title_limit 120
  @description_limit 1_000

  # The board keeps every entry it has ever recorded, so a bounded sweep of the
  # most recent contracts is enough: older ones are already on the board.
  @sweep_limit 200

  # A contract is on the page only while it is the one a studio is offering.
  @live_statuses [:desired, :observed_active]

  @doc """
  The host this deployment is published under, and so the site it files under.
  """
  @spec origin() :: String.t()
  def origin do
    case System.get_env("PHX_HOST") do
      value when is_binary(value) and value != "" -> normalize!(value)
      _ -> @default_origin
    end
  end

  @doc """
  Registers this deployment's own site and records the seeded contract plus
  every contract a studio is currently offering as one entry each.
  """
  @spec mirror!() :: Site.t()
  def mirror! do
    site = Forum.register_site!(origin())

    [seeded_contract() | live_contracts()]
    |> Enum.uniq_by(&{&1.name, &1.contract_sha256})
    |> Enum.map(&Map.put(&1, :site_id, site.id))
    |> observe_all!()

    site
  end

  defp normalize!(value) do
    case Origin.normalize(value) do
      {:ok, host} ->
        host

      {:error, reason} ->
        raise ArgumentError, "PHX_HOST #{inspect(value)} #{reason}"
    end
  end

  defp seeded_contract do
    # The fixture is the definition of the starting contract, so it can be read
    # without a studio existing. Only the contract itself is used here.
    nil |> Fixtures.revision_attributes() |> contract()
  end

  # Oldest first, so a newer contract ends up with the more recent "last seen"
  # and the board lists the versions in publication order.
  defp live_contracts do
    Rooms.list_tool_revisions!(
      query: [
        filter: [status: [in: @live_statuses]],
        sort: [inserted_at: :desc, id: :desc],
        limit: @sweep_limit
      ]
    )
    |> Enum.reverse()
    |> Enum.map(&contract/1)
  end

  defp contract(revision) do
    %{
      name: revision.name,
      contract_sha256: revision.contract_sha256,
      title: clamp(revision.title, @title_limit),
      description: clamp(revision.description, @description_limit)
    }
  end

  # A studio's copy is written for the studio page, which allows longer text
  # than a board entry does.
  defp clamp(nil, _limit), do: nil

  defp clamp(value, limit) when is_binary(value) do
    if String.length(value) > limit, do: String.slice(value, 0, limit), else: value
  end

  defp observe_all!(contracts) do
    Forum.observe_tool!(contracts,
      bulk_options: [return_records?: false, return_errors?: true, stop_on_error?: true]
    )
  end
end
