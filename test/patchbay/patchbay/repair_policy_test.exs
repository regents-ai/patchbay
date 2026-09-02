defmodule Patchbay.Patchbay.RepairPolicyTest do
  @moduledoc """
  The deterministic repair policy is the last gate before a model-shaped plan
  becomes a real v2 contract, so every rejection below must fail closed without
  touching the database.
  """

  use ExUnit.Case, async: true

  alias Patchbay.Patchbay.{Fixtures, RepairPolicy, ToolRevision}

  @room_id "3f1d2c9e-1f6e-4d0b-9a8c-4c6f0f3f2b11"

  setup do
    %{revision: revision(), plan: Fixtures.repair_plan()}
  end

  test "accepts the seeded plan and copies the source input schema verbatim", %{
    revision: revision,
    plan: plan
  } do
    assert :ok = RepairPolicy.validate(plan, revision)
    assert {:ok, attributes} = RepairPolicy.revision_attributes(plan, revision)

    assert attributes.input_schema == revision.input_schema
    assert attributes.generation == 2
    assert attributes.name == "uplift_current_skill_v2"
    assert attributes.annotations["untrustedContentHint"] == true
    assert attributes.postcondition_set == :skill_candidate_written_v1
  end

  test "rejects a broadened input schema", %{revision: revision, plan: plan} do
    broadened =
      revision.input_schema
      |> Map.put("additionalProperties", true)
      |> Map.delete("required")

    assert {:error, :input_schema_must_not_change} =
             RepairPolicy.validate(plan, revision, input_schema: broadened)

    assert {:error, :input_schema_must_not_change} =
             RepairPolicy.revision_attributes(plan, revision, input_schema: broadened)
  end

  test "rejects any input schema change, not only a broadening one", %{
    revision: revision,
    plan: plan
  } do
    narrowed = put_in(revision.input_schema, ["properties", "instructions", "maxLength"], 10)

    assert {:error, :input_schema_must_not_change} =
             RepairPolicy.validate(plan, revision, input_schema: narrowed)

    assert {:error, :input_schema_must_not_change} =
             RepairPolicy.validate(plan, revision, input_schema: %{})

    assert {:error, :input_schema_must_not_change} =
             RepairPolicy.validate(plan, revision, input_schema: "{}")
  end

  test "an identical schema written with atom keys is not a change", %{
    revision: revision,
    plan: plan
  } do
    atom_keyed =
      Map.new(revision.input_schema, fn {key, value} -> {String.to_atom(key), value} end)

    assert :ok = RepairPolicy.validate(plan, revision, input_schema: atom_keyed)
  end

  test "rejects an unknown handler adapter", %{revision: revision, plan: plan} do
    assert {:error, :adapter_not_allowed} =
             RepairPolicy.validate(Map.put(plan, "handler_adapter", "run_javascript"), revision)

    refute RepairPolicy.allowlisted_adapter?(:run_javascript)
  end

  test "rejects a non-allowlisted output contract", %{revision: revision, plan: plan} do
    assert {:error, :output_contract_not_allowed} =
             RepairPolicy.validate(
               Map.put(plan, "output_contract_version", "skill_uplift_verified_v2"),
               revision
             )
  end

  test "rejects a non-allowlisted postcondition set", %{revision: revision, plan: plan} do
    assert {:error, :postcondition_not_allowed} =
             RepairPolicy.validate(
               Map.put(plan, "postcondition_set", "anything_written_v1"),
               revision
             )
  end

  test "rejects a generation that is not previous + 1", %{revision: revision, plan: plan} do
    assert {:error, :generation_must_be_next} =
             RepairPolicy.validate(plan, revision, generation: 3)

    assert {:error, :generation_must_be_next} =
             RepairPolicy.validate(plan, revision, generation: 1)

    assert {:error, :generation_must_be_next} =
             RepairPolicy.revision_attributes(plan, revision, generation: 7)
  end

  test "rejects an over-long description replacement", %{revision: revision, plan: plan} do
    plan = Map.put(plan, "description_replacement", String.duplicate("a", 1_001))

    assert {:error, {:description_replacement, :too_long}} =
             RepairPolicy.validate(plan, revision)
  end

  test "publishes the model's wording followed by Patchbay's own sentence", %{
    revision: revision,
    plan: plan
  } do
    assert {:ok, attributes} = RepairPolicy.revision_attributes(plan, revision)

    assert String.starts_with?(attributes.description, plan["description_replacement"])
    assert String.ends_with?(attributes.description, RepairPolicy.verified_reporting_note())
    assert attributes.description =~ "report_tool_problem"
  end

  test "measures the published description, not just the model's half", %{
    revision: revision,
    plan: plan
  } do
    note_length = byte_size(RepairPolicy.verified_reporting_note())
    plan = Map.put(plan, "description_replacement", String.duplicate("a", 1_000 - note_length))

    assert {:error, :description_too_long} = RepairPolicy.validate(plan, revision)
  end

  test "requires the candidate to keep untrustedContentHint true", %{
    revision: revision,
    plan: plan
  } do
    for hint <- [false, nil, "true"] do
      revision = %{revision | annotations: %{"untrustedContentHint" => hint}}

      assert {:error, :untrusted_content_hint_required} =
               RepairPolicy.validate(plan, revision)
    end

    revision = %{revision | annotations: %{}}
    assert {:error, :untrusted_content_hint_required} = RepairPolicy.validate(plan, revision)
  end

  test "rejects a source revision that is not a usable contract", %{plan: plan} do
    assert {:error, :invalid_source_revision} =
             RepairPolicy.validate(plan, %{revision() | generation: 0})

    assert {:error, :invalid_source_revision} =
             RepairPolicy.validate(plan, %{revision() | input_schema: nil})
  end

  defp revision do
    struct(ToolRevision, Fixtures.revision_attributes(@room_id))
  end
end
