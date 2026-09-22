defmodule Patchbay.Assist.Arguments do
  @moduledoc """
  The arguments a chosen tool is called with: the agent's own when it named
  the tool and they fit its schema, otherwise a draft written from the
  schema, the goal and the expected result, checked against the schema
  before anything is called. Jev is never asked to write them.
  """

  alias Patchbay.Assist.Run
  alias Patchbay.Assist.Schema
  alias Patchbay.Patchbay.OpenAI.Client

  @type source :: :believed | :drafted

  @doc "The arguments to call `tool` with for the run, and where they came from."
  @spec for_tool(Run.t(), map(), keyword()) ::
          {:ok, map(), source()} | {:error, :arguments_unusable | {:provider, term()}}
  def for_tool(%Run{} = run, tool, opts \\ []) do
    case believed(run, tool) do
      {:ok, arguments} -> {:ok, arguments, :believed}
      :none -> drafted(run, tool, opts)
    end
  end

  defp believed(run, tool) do
    run.believed_calls
    |> Enum.find(&(&1["tool"] == tool.name))
    |> case do
      %{"arguments" => arguments} when is_map(arguments) ->
        if Schema.check(arguments, tool.input_schema) == :ok, do: {:ok, arguments}, else: :none

      _unnamed ->
        :none
    end
  end

  defp drafted(run, tool, opts) do
    input = %{
      tool: tool.name,
      description: tool.description,
      input_schema: tool.input_schema || %{},
      goal: run.goal,
      expected_result: run.expected_result
    }

    case Client.draft_arguments(input, opts) do
      {:ok, %{arguments: arguments}} ->
        case Schema.check(arguments, tool.input_schema) do
          :ok -> {:ok, arguments, :drafted}
          {:error, _why} -> {:error, :arguments_unusable}
        end

      {:error, reason} ->
        {:error, {:provider, reason}}
    end
  end
end
