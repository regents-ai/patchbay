defmodule Patchbay.Patchbay.CanaryRunner do
  @moduledoc """
  Runs a deterministic in-memory canary for an audited repair adapter.

  This models only the page-side contract. It never evaluates a Skill's task
  performance and never executes generated code.
  """

  alias Patchbay.Patchbay.{Digest, Frontmatter, PostconditionVerifier, RepairPolicy}

  @spec run(binary(), binary(), struct(), keyword()) :: map()
  def run(source, candidate, revision, _opts \\ []) do
    source_sha256 = digest_or_nil(source)
    candidate_sha256 = digest_or_nil(candidate)
    frontmatter_valid = is_binary(candidate) and Frontmatter.valid?(candidate)
    identity_preserved = PostconditionVerifier.identity_preserved?(source, candidate)
    adapter_allowlisted = RepairPolicy.allowlisted_adapter?(Map.get(revision, :handler_adapter))

    postcondition_allowlisted =
      Map.get(revision, :postcondition_set) == :skill_candidate_written_v1

    revision_contract_valid = revision_contract_valid?(revision)

    output =
      if adapter_allowlisted and frontmatter_valid and identity_preserved and is_binary(candidate) do
        %{
          "reported_success" => true,
          "applied" => true,
          "verified" => true,
          "candidate_sha256" => candidate_sha256,
          "ui_revision" => 1,
          "change_summary" => [],
          "warnings" => ["This candidate has not been evaluated on real tasks."]
        }
      else
        %{"reported_success" => true, "applied" => false, "verified" => false}
      end

    verifier =
      PostconditionVerifier.verify(
        %{
          ui_revision: 0,
          source: %{present: true, sha256: source_sha256},
          candidate: %{present: false, sha256: nil}
        },
        %{
          ui_revision: if(output["applied"], do: 1, else: 0),
          source: %{present: true, sha256: source_sha256},
          candidate: %{
            present: output["applied"],
            sha256: if(output["applied"], do: candidate_sha256, else: nil)
          }
        },
        source_markdown: source,
        candidate_markdown: if(output["applied"], do: candidate, else: nil),
        expected_candidate_sha256: if(output["applied"], do: candidate_sha256, else: nil),
        expected_contract_sha256: Map.get(revision, :contract_sha256),
        observed_contract_sha256:
          if(output["applied"], do: Map.get(revision, :contract_sha256), else: nil),
        expected_browser_session_id: "canary-session",
        observed_browser_session_id: if(output["applied"], do: "canary-session", else: nil)
      )

    checks = %{
      "adapter_allowlisted" => adapter_allowlisted,
      "postcondition_allowlisted" => postcondition_allowlisted,
      "candidate_present" => output["applied"] == true,
      "source_unchanged" => verifier.checks.source_unchanged,
      "candidate_digest_changed" => verifier.checks.candidate_changed,
      "frontmatter_valid" => frontmatter_valid,
      "identity_preserved" => identity_preserved,
      "output_contract_valid" =>
        revision_contract_valid and output_contract_valid?(output, candidate_sha256),
      "ui_revision_advanced" => verifier.checks.ui_revision_advanced
    }

    passed = Enum.all?(checks, fn {_key, value} -> value == true end)

    %{
      passed: passed,
      checks: checks,
      failure_code: if(passed, do: nil, else: verifier.failure_code || :CANARY_FAILED),
      output: output,
      candidate_sha256: candidate_sha256,
      verifier: verifier
    }
  end

  defp output_contract_valid?(output, candidate_sha256) do
    output["reported_success"] == true and output["applied"] == true and
      output["verified"] == true and output["candidate_sha256"] == candidate_sha256 and
      is_integer(output["ui_revision"]) and is_list(output["change_summary"]) and
      is_list(output["warnings"])
  end

  defp revision_contract_valid?(revision) do
    contract = Map.get(revision, :output_contract, %{})

    is_map(contract) and
      Map.get(contract, "reported_success", Map.get(contract, :reported_success)) == true and
      Map.get(contract, "applied", Map.get(contract, :applied)) == true and
      Map.get(contract, "verified", Map.get(contract, :verified)) == true and
      Map.has_key?(contract, "candidate_sha256") and Map.has_key?(contract, "ui_revision")
  end

  defp digest_or_nil(value) when is_binary(value), do: Digest.sha256(value)
  defp digest_or_nil(_), do: nil
end
