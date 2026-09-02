defmodule Patchbay.Patchbay.RepairPolicy do
  @moduledoc """
  Deterministic server policy for turning a parsed repair plan into a v2
  contract. The model selects only an audited adapter and contract; it never
  selects a tool name, generation, approval, or publication state.
  """

  alias Patchbay.Patchbay.{CanonicalJSON, RepairDSL}

  @max_description_bytes 1_000

  # The description is the only place a browser agent learns what this page does
  # with a tool result, so every repaired revision carries the same closing
  # sentence, added by the server rather than chosen by the model.
  @verified_reporting_note "This page verifies tool results against what is visible on screen; a mismatch can be reported with report_tool_problem using the receipt from the result."

  @doc """
  The description a repaired revision is published under: the model's wording,
  then the server's own sentence about how results here are checked.
  """
  @spec published_description(String.t()) :: String.t()
  def published_description(replacement), do: replacement <> " " <> @verified_reporting_note

  @spec verified_reporting_note() :: String.t()
  def verified_reporting_note, do: @verified_reporting_note

  @spec validate(map() | binary(), struct(), keyword()) :: :ok | {:error, atom() | tuple()}
  def validate(plan, source_revision, opts \\ []) do
    with {:ok, plan} <- RepairDSL.parse(plan),
         :ok <- validate_revision(source_revision),
         :ok <- validate_generation(source_revision, opts),
         :ok <-
           validate_input_schema(proposed_input_schema(source_revision, opts), source_revision) do
      validate_contract_metadata(source_revision, plan)
    end
  end

  @doc """
  Fails closed unless the candidate carries the source revision's input schema
  byte for byte. A repair may narrow behaviour behind the same contract; it may
  never restate, reorder, or widen what the tool accepts.
  """
  @spec validate_input_schema(term(), struct()) :: :ok | {:error, atom()}
  def validate_input_schema(proposed, %{input_schema: source}) when is_map(proposed) do
    if CanonicalJSON.encode(proposed) == CanonicalJSON.encode(source),
      do: :ok,
      else: {:error, :input_schema_must_not_change}
  rescue
    ArgumentError -> {:error, :input_schema_must_not_change}
  end

  def validate_input_schema(_proposed, _source_revision),
    do: {:error, :input_schema_must_not_change}

  @spec revision_attributes(map() | binary(), struct(), keyword()) ::
          {:ok, map()} | {:error, atom() | tuple()}
  def revision_attributes(plan, source_revision, opts \\ []) do
    with {:ok, plan} <- RepairDSL.parse(plan),
         :ok <- validate(plan, source_revision, opts) do
      generation = Keyword.get(opts, :generation, source_revision.generation + 1)

      annotations =
        Map.put(string_key_map(source_revision.annotations), "untrustedContentHint", true)

      {:ok,
       %{
         room_id: source_revision.room_id,
         parent_revision_id: source_revision.id,
         generation: generation,
         name: "uplift_current_skill_v#{generation}",
         title: source_revision.title,
         description: published_description(plan.description_replacement),
         input_schema: proposed_input_schema(source_revision, opts),
         annotations: annotations,
         handler_adapter: plan.handler_adapter,
         output_contract: output_contract(),
         postcondition_set: :skill_candidate_written_v1,
         origin: :repair_model,
         status: :candidate
       }}
    end
  end

  @spec output_contract() :: map()
  def output_contract do
    %{
      "reported_success" => true,
      "applied" => true,
      "verified" => true,
      "candidate_sha256" => "sha256",
      "ui_revision" => 0,
      "change_summary" => [],
      "warnings" => ["This candidate has not been evaluated on real tasks."]
    }
  end

  @spec allowlisted_adapter?(atom()) :: boolean()
  def allowlisted_adapter?(adapter), do: adapter in RepairDSL.allowed_adapters()

  defp validate_revision(%{room_id: room_id, generation: generation, input_schema: schema})
       when is_binary(room_id) and is_integer(generation) and generation >= 1 and is_map(schema),
       do: :ok

  defp validate_revision(_), do: {:error, :invalid_source_revision}

  # The schema a repair would publish. It is the source schema unless a caller
  # names one, which is the only seam through which a change could arrive.
  defp proposed_input_schema(%{input_schema: schema}, opts),
    do: Keyword.get(opts, :input_schema, schema)

  defp proposed_input_schema(_revision, opts), do: Keyword.get(opts, :input_schema)

  defp validate_generation(revision, opts) do
    expected = Keyword.get(opts, :generation, revision.generation + 1)

    if expected == revision.generation + 1,
      do: :ok,
      else: {:error, :generation_must_be_next}
  end

  defp validate_contract_metadata(revision, plan) do
    # The published description is what the limit is about, so it is the one
    # measured: the model's wording has to leave room for Patchbay's sentence.
    description = published_description(plan.description_replacement)
    annotations = string_key_map(revision.annotations)

    cond do
      not allowlisted_adapter?(plan.handler_adapter) ->
        {:error, :adapter_not_allowed}

      plan.output_contract_version not in RepairDSL.allowed_output_contracts() ->
        {:error, :output_contract_not_allowed}

      plan.postcondition_set not in RepairDSL.allowed_postconditions() ->
        {:error, :postcondition_not_allowed}

      byte_size(description) > @max_description_bytes ->
        {:error, :description_too_long}

      Map.get(annotations, "untrustedContentHint") != true ->
        {:error, :untrusted_content_hint_required}

      true ->
        :ok
    end
  rescue
    ArgumentError -> {:error, :invalid_contract_metadata}
  end

  defp string_key_map(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), item} end)
  end

  defp string_key_map(_), do: %{}
end
