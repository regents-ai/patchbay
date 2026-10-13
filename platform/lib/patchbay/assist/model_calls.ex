defmodule Patchbay.Assist.ModelCalls do
  @moduledoc """
  The record of every question Patchbay sends a model on OpenRouter
  (`Patchbay.Assist.ModelCall`): opened before the question goes, closed
  with what came back. Each close also emits
  `[:patchbay, :model_call, :stop]` with the tokens and cost as
  measurements and the purpose, model and outcome as metadata.

  The day's readings of posts emit two events of their own, each with the
  readings counted and the ceiling as measurements:
  `[:patchbay, :post_readings, :half_spent]` when the reading that takes
  half the ceiling opens, and `[:patchbay, :post_readings, :day_full]` each
  time a post is refused because the ceiling is reached.
  """

  require Ash.Query
  require Logger

  alias Patchbay.Assist
  alias Patchbay.Assist.ModelCall

  @doc "Opens the record of a question for `purpose`, asked of `model`, for the run `run_id` if any."
  @spec ask(atom(), String.t(), Ash.UUID.t() | nil) :: ModelCall.t()
  def ask(purpose, model, run_id \\ nil) do
    # Patchbay's own record of a question it is about to send.
    Assist.ask_model!(%{purpose: purpose, model: model, assist_run_id: run_id}, authorize?: false)
  end

  @help_per_connection_a_day 1
  @help_a_day 200

  @doc """
  Opens the record of the free help's look-up from the connection
  `visitor_key` names, or `:used_up` when the site's #{@help_a_day} look-ups
  for today, or the connection's #{@help_per_connection_a_day}, are taken.
  Look-ups still in flight count; failed ones do not.
  """
  @spec ask_for_help(String.t(), String.t()) :: {:ok, ModelCall.t()} | :used_up
  def ask_for_help(model, visitor_key) when is_binary(visitor_key) do
    Ash.transact(ModelCall, fn ->
      # Every look-up counts and opens under this lock, held until the open
      # commits, so look-ups sent together cannot both take the last one.
      Patchbay.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "patchbay free help look-ups"
      ])

      since = DateTime.add(DateTime.utc_now(), -1, :day)

      if help_counted(since) < @help_a_day and
           help_counted(since, visitor_key) < @help_per_connection_a_day do
        # Patchbay's own record, opened within the limits just counted.
        Assist.ask_model_for_help!(%{model: model, visitor_key: visitor_key},
          authorize?: false
        )
      else
        :used_up
      end
    end)
    |> case do
      {:ok, %ModelCall{} = call} -> {:ok, call}
      {:ok, :used_up} -> :used_up
    end
  end

  @post_readings_per_person_an_hour 60
  @hour_seconds 60 * 60

  @doc "How many posts one person may send to be read in an hour."
  @spec post_readings_per_person_an_hour() :: pos_integer()
  def post_readings_per_person_an_hour, do: @post_readings_per_person_an_hour

  @doc """
  Opens the record of the reading of a post that goes out for the person
  `person_id`; or `{:hour_full, seconds}` when that person has sent
  #{@post_readings_per_person_an_hour} posts to be read in the past hour,
  with the seconds until one more may be; or `:day_full` when the site has
  read all the posts it may in 24 hours
  (`Patchbay.Config.daily_post_readings/0`).

  Every reading counts, in flight, answered or failed, so neither a burst
  sent together nor a Jev that cannot be reached lets a person past their
  hour's worth. A person's readings are counted and opened under that
  person's lock; the site's ceiling is read without one, so posts sent
  together by different people can overshoot it by a few.
  """
  @spec ask_to_check_post(String.t(), Ash.UUID.t()) ::
          {:ok, ModelCall.t()} | {:hour_full, pos_integer()} | :day_full
  def ask_to_check_post(model, person_id) when is_binary(person_id) do
    {:ok, opened} =
      Ash.transact(ModelCall, fn ->
        Patchbay.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
          "patchbay post readings " <> person_id
        ])

        now = DateTime.utc_now()

        case person_hour_full(person_id, now) do
          nil -> open_reading(model, person_id, now)
          seconds -> {:hour_full, seconds}
        end
      end)

    opened
  end

  defp open_reading(model, person_id, now) do
    counted = readings_counted(DateTime.add(now, -1, :day))
    ceiling = Patchbay.Config.daily_post_readings()

    if counted < ceiling do
      if (counted + 1) * 2 == ceiling, do: readings_event(:half_spent, counted + 1, ceiling)

      # Patchbay's own record, opened within the limits just counted.
      {:ok,
       Assist.ask_model_to_check_post!(%{model: model, visitor_key: person_id},
         authorize?: false
       )}
    else
      readings_event(:day_full, counted, ceiling)

      Logger.warning(
        "The day's post readings are spent (#{counted} of #{ceiling}): nothing is posted until some free up"
      )

      :day_full
    end
  end

  defp readings_event(event, counted, ceiling) do
    :telemetry.execute(
      [:patchbay, :post_readings, event],
      %{count: counted, ceiling: ceiling},
      %{}
    )
  end

  # The seconds until this person's oldest reading of the past hour leaves
  # it, when the hour is full; `nil` when there is room.
  defp person_hour_full(person_id, now) do
    since = DateTime.add(now, -@hour_seconds)

    # Patchbay's own records of one person's readings, read for a limit.
    recent =
      ModelCall
      |> Ash.Query.filter(
        purpose == :check_post and visitor_key == ^person_id and inserted_at > ^since
      )
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.Query.limit(@post_readings_per_person_an_hour)
      |> Ash.read!(authorize?: false)

    if length(recent) >= @post_readings_per_person_an_hour do
      recent
      |> hd()
      |> Map.fetch!(:inserted_at)
      |> DateTime.add(@hour_seconds)
      |> DateTime.diff(now)
      |> max(1)
    end
  end

  # Same: the site's readings, for its ceiling.
  defp readings_counted(since) do
    ModelCall
    |> Ash.Query.filter(purpose == :check_post and inserted_at >= ^since)
    |> Ash.count!(authorize?: false)
  end

  @doc """
  Closes `call` with what the provider answered, and hands that answer back
  unchanged. `tokens` names the answer's `usage` fields holding the tokens
  sent and received, since each OpenRouter endpoint names its own.
  """
  @spec close(ModelCall.t(), {:ok, map()} | {:error, term()}, {String.t(), String.t()}) ::
          {:ok, map()} | {:error, term()}
  def close(%ModelCall{} = call, {:ok, body} = answered, {sent, received}) do
    usage = if is_map(body["usage"]), do: body["usage"], else: %{}

    # Patchbay's own record, closed with what the provider said it used.
    closed =
      Assist.close_model_call!(
        call,
        %{
          prompt_tokens: integer(usage[sent]),
          completion_tokens: integer(usage[received]),
          cost_usd: cost(usage["cost"])
        },
        authorize?: false
      )

    emit(closed)
    answered
  end

  def close(%ModelCall{} = call, {:error, _reason} = failed, _tokens) do
    # Same: the question got no answer.
    call |> Assist.fail_model_call!(authorize?: false) |> emit()
    failed
  end

  # Counts of Patchbay's own records, read for a limit.
  defp help_counted(since) do
    help_lookups(since) |> Ash.count!(authorize?: false)
  end

  # Same: the connection's own look-ups, for its limit alone.
  defp help_counted(since, visitor_key) do
    help_lookups(since)
    |> Ash.Query.filter(visitor_key == ^visitor_key)
    |> Ash.count!(authorize?: false)
  end

  defp help_lookups(since) do
    Ash.Query.filter(
      ModelCall,
      purpose == :known_fix_for_help and outcome != :failed and inserted_at >= ^since
    )
  end

  defp integer(value) when is_integer(value), do: value
  defp integer(_missing), do: nil

  defp cost(value) when is_number(value), do: value
  defp cost(_missing), do: nil

  defp emit(%ModelCall{} = call) do
    :telemetry.execute(
      [:patchbay, :model_call, :stop],
      %{
        prompt_tokens: call.prompt_tokens || 0,
        completion_tokens: call.completion_tokens || 0,
        cost_usd: if(call.cost_usd, do: Decimal.to_float(call.cost_usd), else: 0.0)
      },
      %{purpose: call.purpose, model: call.model, outcome: call.outcome}
    )
  end
end
