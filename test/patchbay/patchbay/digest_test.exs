defmodule Patchbay.Patchbay.DigestTest do
  use ExUnit.Case, async: true

  alias Patchbay.Patchbay.Digest

  test "canonical contract digest is stable across map ordering" do
    first = %{
      name: "uplift_current_skill_v1",
      title: "Improve the current Skill",
      description: "Improve the current Skill.",
      input_schema: %{"type" => "object", "required" => ["instructions"]},
      annotations: %{"untrustedContentHint" => true, "readOnlyHint" => false},
      handler_adapter: :return_candidate_only,
      output_contract: %{"reported_success" => true},
      postcondition_set: :skill_candidate_written_v1
    }

    second = %{
      postcondition_set: :skill_candidate_written_v1,
      output_contract: %{"reported_success" => true},
      handler_adapter: :return_candidate_only,
      annotations: %{"readOnlyHint" => false, "untrustedContentHint" => true},
      input_schema: %{"required" => ["instructions"], "type" => "object"},
      description: "Improve the current Skill.",
      title: "Improve the current Skill",
      name: "uplift_current_skill_v1"
    }

    assert Digest.contract_sha256(first) == Digest.contract_sha256(second)
  end

  test "a one-byte contract change changes its digest" do
    contract = %{
      name: "uplift_current_skill_v1",
      title: "Improve the current Skill",
      description: "Improve the current Skill.",
      input_schema: %{},
      annotations: %{},
      handler_adapter: :return_candidate_only,
      output_contract: %{},
      postcondition_set: :skill_candidate_written_v1
    }

    changed = %{contract | description: "Improve the current Skill!"}
    refute Digest.contract_sha256(contract) == Digest.contract_sha256(changed)
  end

  test "generation keys bind source digest and canonical arguments" do
    source_digest = Digest.sha256("source")
    arguments = %{"instructions" => "be concise"}

    assert Digest.generation_key(source_digest, arguments) ==
             Digest.generation_key(source_digest, %{instructions: "be concise"})

    refute Digest.generation_key(source_digest, arguments) ==
             Digest.generation_key(Digest.sha256("changed"), arguments)
  end

  test "artifact size is bounded in UTF-8 bytes" do
    max = Digest.max_artifact_bytes()
    assert Digest.artifact_size(String.duplicate("a", max)) == max
    assert Digest.validate_artifact(String.duplicate("a", max)) == :ok

    assert Digest.validate_artifact(String.duplicate("a", max + 1)) ==
             {:error, :artifact_too_large}
  end

  test "canonical JSON rejects atom and string keys that normalize to one key" do
    assert_raise ArgumentError, ~r/duplicate canonical JSON key/, fn ->
      Patchbay.Patchbay.CanonicalJSON.encode(Map.put(%{"name" => "string"}, :name, "atom"))
    end
  end
end
