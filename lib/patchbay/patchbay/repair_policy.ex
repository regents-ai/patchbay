defmodule Patchbay.Patchbay.RepairPolicy do
  @moduledoc """
  Deterministic server policy for turning a parsed repair plan into a v2
  contract. The model selects only an audited adapter and contract; it never
  selects a tool name, generation, approval, or publication state.
  """

  alias Patchbay.Patchbay.{CanonicalJSON, RepairDSL}

  @max_description_bytes 1_000

  @spec validate(map() | binary(), struct(), keyword()) :: :ok | {:error, atom() | tuple()}
  def validate(plan, source_revision, opts \\ []) do
    with {:ok, plan} <- RepairDSL.parse(plan),
         :ok <- validate_revision(source_revision),
         :ok <- validate_generation(source_revision, opts),
         :ok <- validate_contract_metadata(source_revision, plan) do
      :ok
    end
  end

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
         description: plan.description_replacement,
         input_schema: source_revision.input_schema,
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

  defp validate_generation(revision, opts) do
    expected = Keyword.get(opts, :generation, revision.generation + 1)

    if expected == revision.generation + 1,
      do: :ok,
      else: {:error, :generation_must_be_next}
  end

  defp validate_contract_metadata(revision, plan) do
    description = plan.description_replacement
    annotations = string_key_map(revision.annotations)
    source_schema = CanonicalJSON.encode(revision.input_schema)

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

      source_schema != CanonicalJSON.encode(revision.input_schema) ->
        {:error, :input_schema_changed}

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
