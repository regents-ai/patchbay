defmodule Patchbay.Patchbay.CanaryRunner do
  @moduledoc """
  Runs a deterministic in-memory canary for an audited repair adapter.

  This models only the page-side contract. It never evaluates a Skill's task
  performance and never executes generated code.
  """

  alias Patchbay.Patchbay.{Digest, Frontmatter, PostconditionVerifier, RepairPolicy}

  @spec run(binary(), binary(), struct(), keyword()) :: map()
  def run(source, candidate, revision, _opts \\ []) do
    facts = facts(source, candidate, revision)
    output = output(facts)
    verifier = verify(facts, output)
    checks = checks(facts, output, verifier)
    passed = Enum.all?(checks, fn {_key, value} -> value == true end)

    %{
      passed: passed,
      checks: checks,
      failure_code: if(passed, do: nil, else: verifier.failure_code || :CANARY_FAILED),
      output: output,
      candidate_sha256: facts.candidate_sha256,
      verifier: verifier
    }
  end

  # Everything the canary decides from, read once: the two Skills, their digests,
  # and what the revision itself declares.
  defp facts(source, candidate, revision) do
    %{
      source: source,
      candidate: candidate,
      source_sha256: digest_or_nil(source),
      candidate_sha256: digest_or_nil(candidate),
      contract_sha256: Map.get(revision, :contract_sha256),
      frontmatter_valid: is_binary(candidate) and Frontmatter.valid?(candidate),
      identity_preserved: PostconditionVerifier.identity_preserved?(source, candidate),
      adapter_allowlisted: RepairPolicy.allowlisted_adapter?(Map.get(revision, :handler_adapter)),
      postcondition_allowlisted:
        Map.get(revision, :postcondition_set) == :skill_candidate_written_v1,
      revision_contract_valid: revision_contract_valid?(revision)
    }
  end

  # The stand-in handler writes the candidate only when it is allowed to and the
  # candidate is one it may write. Everything else comes back untouched, which is
  # what the checks below then read as a failure.
  defp output(
         %{
           adapter_allowlisted: true,
           frontmatter_valid: true,
           identity_preserved: true,
           candidate: candidate
         } = facts
       )
       when is_binary(candidate) do
    %{
      "reported_success" => true,
      "applied" => true,
      "verified" => true,
      "candidate_sha256" => facts.candidate_sha256,
      "ui_revision" => 1,
      "change_summary" => [],
      "warnings" => ["This candidate has not been evaluated on real tasks."]
    }
  end

  defp output(_facts),
    do: %{"reported_success" => true, "applied" => false, "verified" => false}

  # The snapshots a real page would have sent, built from what the stand-in
  # handler did. A handler that wrote nothing observed nothing.
  defp verify(facts, output) do
    applied = output["applied"]

    PostconditionVerifier.verify(
      %{
        ui_revision: 0,
        source: %{present: true, sha256: facts.source_sha256},
        candidate: %{present: false, sha256: nil}
      },
      %{
        ui_revision: if(applied, do: 1, else: 0),
        source: %{present: true, sha256: facts.source_sha256},
        candidate: %{present: applied, sha256: when_applied(applied, facts.candidate_sha256)}
      },
      source_markdown: facts.source,
      candidate_markdown: when_applied(applied, facts.candidate),
      expected_candidate_sha256: when_applied(applied, facts.candidate_sha256),
      expected_contract_sha256: facts.contract_sha256,
      observed_contract_sha256: when_applied(applied, facts.contract_sha256),
      expected_browser_session_id: "canary-session",
      observed_browser_session_id: when_applied(applied, "canary-session")
    )
  end

  defp when_applied(true, value), do: value
  defp when_applied(false, _value), do: nil

  defp checks(facts, output, verifier) do
    %{
      adapter_allowlisted: facts.adapter_allowlisted,
      postcondition_allowlisted: facts.postcondition_allowlisted,
      candidate_present: output["applied"] == true,
      source_unchanged: verifier.checks.source_unchanged,
      candidate_digest_changed: verifier.checks.candidate_changed,
      frontmatter_valid: facts.frontmatter_valid,
      identity_preserved: facts.identity_preserved,
      output_contract_valid:
        facts.revision_contract_valid and output_contract_valid?(output, facts.candidate_sha256),
      ui_revision_advanced: verifier.checks.ui_revision_advanced
    }
  end

  # The same promise, read off what the handler returned rather than off what
  # the revision declared. The keys are strings here and atoms in the check
  # below because these are two different records: a handler result is the
  # browser's JSON as received, while an output contract is the declared
  # OutputContract type Ash has already cast. The stand-in handler above answers
  # in the browser's shape, since that is the shape a real call has to satisfy.
  defp output_contract_valid?(output, candidate_sha256) do
    output["reported_success"] == true and output["applied"] == true and
      output["verified"] == true and output["candidate_sha256"] == candidate_sha256 and
      is_integer(output["ui_revision"]) and is_list(output["change_summary"]) and
      is_list(output["warnings"])
  end

  # A revision's own contract, which OutputContract has already canonicalised.
  # Only a contract that promises an applied and verified change, and names the
  # candidate digest and editor revision it will report, can pass a canary.
  defp revision_contract_valid?(revision) do
    case Map.get(revision, :output_contract) do
      %{reported_success: true, applied: true, verified: true} = contract ->
        Map.has_key?(contract, :candidate_sha256) and Map.has_key?(contract, :ui_revision)

      _contract ->
        false
    end
  end

  defp digest_or_nil(value) when is_binary(value), do: Digest.sha256(value)
  defp digest_or_nil(_), do: nil
end
