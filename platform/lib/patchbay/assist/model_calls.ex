defmodule Patchbay.Assist.ModelCalls do
  @moduledoc """
  The record of every question Patchbay sends a model on OpenRouter
  (`Patchbay.Assist.ModelCall`): opened before the question goes, closed
  with what came back. Each close also emits
  `[:patchbay, :model_call, :stop]` with the tokens and cost as
  measurements and the purpose, model and outcome as metadata.
  """

  require Ash.Query

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
