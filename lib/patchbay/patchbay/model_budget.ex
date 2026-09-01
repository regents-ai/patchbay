defmodule Patchbay.Patchbay.ModelBudget do
  @moduledoc """
  Spend limits for live model calls.

  The room is public and unauthenticated while every live call is billed to one
  server-side key, so the limits are deliberately blunt: a room may start one
  candidate generation every `PATCHBAY_ROOM_COOLDOWN_SECONDS`, a room may make
  `PATCHBAY_ROOM_DAILY_MODEL_CALLS` live calls in any rolling 24 hours, and the
  whole deployment may make `PATCHBAY_DAILY_MODEL_CALLS` in that window.

  Counting reads durable evidence, never a counter held in memory: invocations
  that recorded live candidate provenance, and repair proposals that recorded a
  live plan model. Two rows can share one paid call, because a candidate served
  from the cache repeats the generation key of the call that produced it, so
  candidate calls are counted as distinct generation keys rather than as rows.
  """

  require Ash.Query

  alias Patchbay.Config
  alias Patchbay.Patchbay.{Invocation, RepairProposal}

  # A repair proposal records the model that produced its plan. These two names
  # mean no model was called: the checked-in demo fixture, and a plan handed to
  # the planner by its caller.
  @offline_plan_models ["patchbay-demo-fallback", "provided-plan"]

  @window_seconds 24 * 60 * 60

  @type call_kind :: :candidate | :repair

  @doc """
  Decides whether a live model call may start for a room right now.

  `room_id` may be `nil` for a call made outside any room; only the
  deployment-wide ceiling applies to those.
  """
  @spec allow(binary() | nil, call_kind()) :: :ok | {:error, String.t()}
  def allow(room_id, kind)
      when (is_binary(room_id) or is_nil(room_id)) and kind in [:candidate, :repair] do
    now = DateTime.utc_now()
    since = DateTime.add(now, -@window_seconds, :second)

    with :ok <- within_cooldown(room_id, kind, now),
         :ok <- within_room_cap(room_id, since) do
      within_deployment_cap(since)
    end
  end

  defp within_cooldown(nil, _kind, _now), do: :ok
  defp within_cooldown(_room_id, :repair, _now), do: :ok

  defp within_cooldown(room_id, :candidate, now) do
    cooldown = Config.room_cooldown_seconds()

    case last_live_candidate_at(room_id) do
      nil ->
        :ok

      started_at ->
        remaining = cooldown - DateTime.diff(now, started_at, :second)

        if remaining > 0 do
          {:error,
           "This room asked the model for a candidate moments ago. Try again in #{remaining} #{pluralize(remaining, "second")}."}
        else
          :ok
        end
    end
  end

  defp within_room_cap(nil, _since), do: :ok

  defp within_room_cap(room_id, since) do
    cap = Config.room_daily_model_calls()

    if live_calls(room_id, since) < cap do
      :ok
    else
      {:error,
       "This room has used all #{cap} of its model calls for the last 24 hours. Try again later."}
    end
  end

  defp within_deployment_cap(since) do
    cap = Config.daily_model_calls()

    if live_calls(nil, since) < cap do
      :ok
    else
      {:error,
       "Patchbay has used all #{cap} of its model calls for the last 24 hours. Try again later."}
    end
  end

  defp live_calls(room_id, since) do
    live_candidate_calls(room_id, since) + live_repair_calls(room_id, since)
  end

  defp live_candidate_calls(room_id, since) do
    live_candidates(room_id)
    |> Ash.Query.filter(started_at >= ^since)
    |> Ash.aggregate!({:live_calls, :count, field: :generation_key, uniq?: true})
    |> Map.fetch!(:live_calls)
  end

  defp live_repair_calls(room_id, since) do
    RepairProposal
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(inserted_at >= ^since and model not in ^@offline_plan_models)
    |> scope_to_room(room_id)
    |> Ash.count!()
  end

  defp last_live_candidate_at(room_id) do
    invocation =
      live_candidates(room_id)
      |> Ash.Query.sort(started_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.Query.select([:started_at])
      |> Ash.read_one!()

    invocation && invocation.started_at
  end

  # An invocation records candidate provenance only once a candidate exists, and
  # `fallback_used` separates a paid call from the checked-in demo fixture.
  defp live_candidates(room_id) do
    Invocation
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      type(handler_result[:candidate_provenance][:fallback_used], :boolean) == false
    )
    |> scope_to_room(room_id)
  end

  defp scope_to_room(query, nil), do: query
  defp scope_to_room(query, room_id), do: Ash.Query.filter(query, room_id == ^room_id)

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"
end
