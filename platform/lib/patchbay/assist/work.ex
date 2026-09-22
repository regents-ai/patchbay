defmodule Patchbay.Assist.Work do
  @moduledoc """
  One paid assist, from the payment landing to the answer.

  Patchbay finds out what tools the site offers, asks Jev which one fits,
  calls it with arguments that fit its schema, asks Jev what the answer
  means, and tries the next tool while there is one and the run is within
  its limits. Every step is written down as it happens, so a run that stops
  short still says what was tried and why it stopped. A site whose tools
  cannot be reached from here gets the call Patchbay would have made,
  marked as a suggestion.

  Nothing here retries on its own, and nothing is sent to the site but the
  run's own request: no cookies, no credentials, no agent identity.
  """

  require Logger

  alias Patchbay.Assist
  alias Patchbay.Assist.Arguments
  alias Patchbay.Assist.Discovery
  alias Patchbay.Assist.Judge
  alias Patchbay.Assist.McpClient
  alias Patchbay.Assist.Run
  alias Patchbay.Patchbay.ModelBudget

  @max_calls 12
  @max_questions 14
  @max_seconds 120

  @doc "Whether the run with `run_id` is one Patchbay picked up now, and everything after that."
  @spec run(Ash.UUID.t()) :: :ok
  def run(run_id) do
    # Patchbay's own worker: the run was bought and answers to no request now.
    with {:ok, %Run{} = run} <- Assist.get_run(run_id, authorize?: false),
         {:ok, run} <- Assist.start_run(run, authorize?: false) do
      work(run)
    else
      _not_waiting -> :ok
    end
  end

  defp work(run) do
    budget = %{
      until: System.monotonic_time(:millisecond) + @max_seconds * 1_000,
      calls: 0,
      questions: 0
    }

    case ModelBudget.allow(nil, :assist) do
      :ok ->
        run |> discover(budget) |> then(fn _ -> :ok end)

      {:error, why} ->
        run
        |> note("Patchbay is out of model calls for today: #{why}")
        |> finish(:assessment_pending, :provider_unavailable)
    end
  rescue
    error -> stopped(run.id, Exception.message(error))
  catch
    :exit, reason -> stopped(run.id, inspect(reason))
  end

  # The run is read again before the note goes on: the one the work started
  # from is behind by every step written since, and those are kept.
  defp stopped(run_id, why) do
    Logger.error("Assist #{run_id} stopped on an error: #{why}")

    # Patchbay's own worker closing the run it was working on.
    {:ok, latest} = Assist.get_run(run_id, authorize?: false)

    latest
    |> note("Patchbay hit an error while working on this and stopped.")
    |> finish(:failed, nil)

    :ok
  end

  # What a run carries between steps: how the site's tools are reached, the
  # tools, the ones tried so far, and how much of the run's limits is left.
  defp discover(run, budget) do
    case Discovery.find(run, target_options()) do
      {:live, client, tools} ->
        run
        |> note("The site answers as an MCP server and lists #{length(tools)} tools.")
        |> attempt(%{mode: {:live, client}, tools: tools, tried: [], budget: budget})

      {:directory, tools} ->
        run
        |> note(
          "The site's tools live in its pages, which Patchbay cannot call from here; " <>
            "the #{length(tools)} tools Patchbay knows for it stand in, so the answer is a suggestion."
        )
        |> attempt(%{mode: :directory, tools: tools, tried: [], budget: budget})

      {:unlisted, why} ->
        run
        |> note(unlisted(why))
        |> finish(:finished, :tools_unlisted)
    end
  end

  defp attempt(run, ctx) do
    candidates = ctx.tools |> Enum.reject(&(&1.name in ctx.tried)) |> Judge.candidates()

    cond do
      candidates == [] ->
        run
        |> note("Every listed tool was tried.")
        |> finish(:finished, :not_possible)

      over?(ctx.budget) ->
        run
        |> note(
          "Stopped at the run's limit: #{ctx.budget.calls} calls to the site and " <>
            "#{ctx.budget.questions} questions to Jev in #{@max_seconds} seconds."
        )
        |> finish(:finished, :not_possible)

      true ->
        choose(run, candidates, ctx)
    end
  end

  defp choose(run, candidates, ctx) do
    ctx = spend(ctx, :questions)

    case Judge.choose_tool(run, candidates, ctx.tried) do
      {:ok, %{name: name, confidence: confidence}} ->
        tool = Enum.find(candidates, &(&1.name == name))

        run
        |> note("Jev read #{name} as the tool to try (confidence #{round(confidence * 100)}%).")
        |> with_arguments(tool, ctx)

      {:error, reason} ->
        provider_unavailable(run, reason)
    end
  end

  defp with_arguments(run, tool, ctx) do
    case Arguments.for_tool(run, tool, model_options()) do
      {:ok, arguments, source} ->
        run
        |> note(arguments_note(tool.name, source))
        |> call(tool, arguments, ctx)

      {:error, :arguments_unusable} ->
        run
        |> note(
          "No arguments could be written for #{tool.name} that fit what it takes; moving on."
        )
        |> attempt(tried(ctx, tool))

      {:error, {:provider, reason}} ->
        provider_unavailable(run, reason)
    end
  end

  # A tool that cannot be called from here, or that the site marks as one
  # that changes things, is suggested rather than called.
  defp call(run, tool, arguments, %{mode: :directory}) do
    run
    |> step(tool.name, arguments, nil, nil, "Suggested: call this tool with these arguments.")
    |> finish(:finished, :suggested)
  end

  defp call(run, %{destructive?: true} = tool, arguments, _ctx) do
    run
    |> step(
      tool.name,
      arguments,
      nil,
      nil,
      "Suggested, not called: the site marks this tool as one that changes things, " <>
        "and Patchbay does not make such calls on anyone's behalf."
    )
    |> finish(:finished, :suggested)
  end

  defp call(run, tool, arguments, %{mode: {:live, client}} = ctx) do
    ctx = spend(ctx, :calls)

    case McpClient.call_tool(client, tool.name, arguments) do
      {:ok, %{text: text, error?: error?}} ->
        judge(run, tool, arguments, {Judge.excerpt(text), error?}, ctx)

      {:error, reason} ->
        run
        |> step(
          tool.name,
          arguments,
          nil,
          nil,
          "The site did not answer this call: #{why(reason)}"
        )
        |> attempt(tried(ctx, tool))
    end
  end

  defp judge(run, tool, arguments, {answer, error?}, ctx) do
    ctx = spend(ctx, :questions)

    case Judge.judge_answer(run, tool.name, answer, error?) do
      {:ok, %{verdict: verdict, confidence: confidence}} ->
        run
        |> step(tool.name, arguments, answer, reading(verdict, confidence), nil)
        |> conclude(verdict, tried(ctx, tool))

      {:error, reason} ->
        run
        |> step(tool.name, arguments, answer, nil, nil)
        |> provider_unavailable(reason)
    end
  end

  defp conclude(run, :try_next, ctx), do: attempt(run, ctx)
  defp conclude(run, :reached, _ctx), do: finish(run, :finished, :reached)

  defp conclude(run, verdict, _ctx)
       when verdict in [:confusing_instructions, :not_possible, :needs_sign_in],
       do: finish(run, :finished, verdict)

  defp spend(ctx, what), do: update_in(ctx, [:budget, what], &(&1 + 1))
  defp tried(ctx, tool), do: %{ctx | tried: ctx.tried ++ [tool.name]}

  defp provider_unavailable(run, reason) do
    Logger.warning(
      "Assist #{run.id}: Jev or the drafting model was unavailable: #{inspect(reason)}"
    )

    run
    |> note(
      "Patchbay's helper was unavailable; a person at Patchbay will finish this. The payment stands."
    )
    |> finish(:assessment_pending, :provider_unavailable)
  end

  defp over?(budget) do
    budget.calls >= @max_calls or budget.questions >= @max_questions or
      System.monotonic_time(:millisecond) >= budget.until
  end

  # Writing the run down. Every write is Patchbay's own, on a run it is working on.
  defp note(run, text), do: record(run, %{"note" => text})

  defp step(run, tool, arguments, answer, reading, text) do
    record(
      run,
      %{"tool" => tool, "arguments" => arguments, "answer" => answer, "reading" => reading}
      |> then(&if(text, do: Map.put(&1, "note", text), else: &1))
    )
  end

  # The worker writes the run it was handed and no other; the run's actions
  # for moving it along are reachable from nowhere else, so authorization is
  # skipped here deliberately. What a site or a model wrote goes in without
  # the one byte the record cannot hold.
  defp record(run, step), do: Assist.record_step!(run, scrubbed(step), authorize?: false)

  defp scrubbed(%{} = map), do: Map.new(map, fn {key, value} -> {key, scrubbed(value)} end)
  defp scrubbed(list) when is_list(list), do: Enum.map(list, &scrubbed/1)
  defp scrubbed(text) when is_binary(text), do: String.replace(text, <<0>>, "")
  defp scrubbed(other), do: other

  # Same as `record/2`: Patchbay's own worker closing its own run.
  defp finish(run, status, outcome),
    do: Assist.finish_run!(run, %{status: status, outcome: outcome}, authorize?: false)

  defp reading(verdict, confidence),
    do: %{"verdict" => Atom.to_string(verdict), "confidence" => confidence, "by" => "jev"}

  defp arguments_note(tool, :believed),
    do: "Calling #{tool} with the arguments the agent gave for it."

  defp arguments_note(tool, :drafted),
    do: "Calling #{tool} with arguments drafted from its schema and the goal."

  defp unlisted(:no_tools_offered), do: "The site answers as an MCP server but offers no tools."

  defp unlisted(:no_tools_known),
    do: "The site does not answer as an MCP server, and Patchbay knows no tools for it."

  defp unlisted(:unresolvable), do: "The site's name does not resolve to any address."

  defp unlisted(:not_public),
    do:
      "The site's name resolves to an address off the public internet, which Patchbay does not call."

  defp unlisted(:unreachable), do: "The site could not be reached."

  defp why({:rpc_error, _code, message}) when message != "", do: message
  defp why({:status, status}), do: "it answered with status #{status}"
  defp why(:timeout), do: "it did not answer in time"
  defp why(:answer_too_long), do: "its answer was longer than Patchbay reads"
  defp why(_other), do: "it did not answer"

  defp target_options, do: Application.get_env(:patchbay, :assist_target, [])
  defp model_options, do: Application.get_env(:patchbay, :assist_model_options, [])
end
