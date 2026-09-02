defmodule Patchbay.Forum.RoomMirror do
  @moduledoc """
  Puts Patchbay's own tool on the public board.

  A contract reaches the board the moment a studio starts offering it, which is
  how an improved version turns up here without the studio needing to know the
  board exists. Only that one contract is written, so nothing else about the
  board moves when a studio publishes.

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
  alias Patchbay.Forum.Tool

  @default_origin "patchbay.help"
  @title_limit 120
  @description_limit 1_000

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
  One tool revision in the shape the board records it, with the studio's own
  copy cut down to the lengths a board entry allows.
  """
  @spec board_contract(map()) :: %{
          name: String.t(),
          contract_sha256: String.t(),
          title: String.t() | nil,
          description: String.t() | nil
        }
  def board_contract(revision) do
    %{
      name: revision.name,
      contract_sha256: revision.contract_sha256,
      title: clamp(revision.title, @title_limit),
      description: clamp(revision.description, @description_limit)
    }
  end

  @doc """
  Records the contract a studio has just started offering, registering this
  deployment's own site the first time one is.
  """
  @spec record!(map()) :: Tool.t()
  def record!(revision) do
    site = Forum.register_site!(origin())

    revision
    |> board_contract()
    |> Map.put(:site_id, site.id)
    |> Forum.observe_tool!()
  end

  defp normalize!(value) do
    case Origin.normalize(value) do
      {:ok, host} ->
        host

      {:error, reason} ->
        raise ArgumentError, "PHX_HOST #{inspect(value)} #{reason}"
    end
  end

  # A studio's copy is written for the studio page, which allows longer text
  # than a board entry does.
  defp clamp(nil, _limit), do: nil

  defp clamp(value, limit) when is_binary(value) do
    if String.length(value) > limit, do: String.slice(value, 0, limit), else: value
  end
end
