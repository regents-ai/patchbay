defmodule Patchbay.Patchbay.PostconditionVerifierTest do
  use ExUnit.Case, async: true

  alias Patchbay.Patchbay.{Digest, Fixtures, PostconditionVerifier}

  setup do
    source = Fixtures.source_markdown()
    candidate = Fixtures.improved_markdown()
    source_sha256 = Digest.sha256(source)
    candidate_sha256 = Digest.sha256(candidate)

    {:ok,
     source: source,
     candidate: candidate,
     source_sha256: source_sha256,
     candidate_sha256: candidate_sha256}
  end

  test "v1 false-success post-state fails because the candidate is not visible", context do
    result =
      PostconditionVerifier.verify(
        %{
          ui_revision: 0,
          source: %{sha256: context.source_sha256},
          candidate: %{present: false, sha256: nil}
        },
        %{
          ui_revision: 0,
          source: %{sha256: context.source_sha256},
          candidate: %{present: false, sha256: nil}
        },
        expected_candidate_sha256: context.candidate_sha256
      )

    refute result.passed
    assert result.failure_code == :CANDIDATE_EMPTY
  end

  test "v2 visible post-state passes all required checks", context do
    result =
      PostconditionVerifier.verify(
        %{
          ui_revision: 0,
          source: %{sha256: context.source_sha256},
          candidate: %{present: false, sha256: nil}
        },
        %{
          ui_revision: 1,
          source: %{sha256: context.source_sha256},
          candidate: %{present: true, sha256: context.candidate_sha256}
        },
        source_markdown: context.source,
        candidate_markdown: context.candidate,
        expected_candidate_sha256: context.candidate_sha256,
        expected_contract_sha256: "contract",
        observed_contract_sha256: "contract",
        expected_browser_session_id: "session-1",
        observed_browser_session_id: "session-1"
      )

    assert result.passed
    assert Enum.all?(PostconditionVerifier.required_checks(), &result.checks[&1])
    assert PostconditionVerifier.valid_result?(result)

    refute PostconditionVerifier.valid_result?(Map.put(result, :failure_code, :CANDIDATE_EMPTY))

    preexisting_candidate =
      PostconditionVerifier.verify(
        %{
          ui_revision: 1,
          source: %{sha256: context.source_sha256},
          candidate: %{present: true, sha256: context.candidate_sha256}
        },
        %{
          ui_revision: 2,
          source: %{sha256: context.source_sha256},
          candidate: %{present: true, sha256: context.candidate_sha256}
        },
        source_markdown: context.source,
        candidate_markdown: context.candidate,
        expected_candidate_sha256: context.candidate_sha256,
        expected_contract_sha256: "contract",
        observed_contract_sha256: "contract",
        expected_browser_session_id: "session-1",
        observed_browser_session_id: "session-1"
      )

    refute preexisting_candidate.passed
    refute preexisting_candidate.checks.candidate_changed
  end

  test "source mutation, stale contract, and stale browser session fail", context do
    result =
      PostconditionVerifier.verify(
        %{ui_revision: 0, source: %{sha256: context.source_sha256}},
        %{
          ui_revision: 1,
          source: %{sha256: Digest.sha256("mutated")},
          candidate: %{present: true, sha256: context.candidate_sha256}
        },
        source_markdown: context.source,
        candidate_markdown: context.candidate,
        expected_candidate_sha256: context.candidate_sha256,
        expected_contract_sha256: "current",
        observed_contract_sha256: "stale",
        expected_browser_session_id: "session-1",
        observed_browser_session_id: "session-2"
      )

    refute result.passed
    refute result.checks.source_unchanged
    refute result.checks.tool_contract_current
    refute result.checks.browser_session_current
  end

  test "candidate digest is recomputed and independent baselines are required", context do
    result =
      PostconditionVerifier.verify(
        %{
          ui_revision: 0,
          source: %{sha256: context.source_sha256},
          candidate: %{present: false, sha256: nil}
        },
        %{
          ui_revision: 1,
          source: %{sha256: context.source_sha256},
          candidate: %{present: true, sha256: Digest.sha256("spoofed")}
        },
        source_markdown: context.source,
        candidate_markdown: context.candidate,
        expected_candidate_sha256: context.candidate_sha256,
        expected_contract_sha256: "contract",
        observed_contract_sha256: "contract",
        expected_browser_session_id: "session-1",
        observed_browser_session_id: "session-1"
      )

    assert result.candidate_sha256 == context.candidate_sha256
    refute result.passed
    refute result.checks.candidate_matches_server

    missing_baselines =
      PostconditionVerifier.verify(
        %{ui_revision: 0, source: %{sha256: context.source_sha256}},
        %{ui_revision: 1, source: %{sha256: context.source_sha256}},
        source_markdown: context.source,
        candidate_markdown: context.candidate
      )

    refute missing_baselines.passed
    refute missing_baselines.checks.candidate_matches_server
    refute missing_baselines.checks.tool_contract_current
    refute missing_baselines.checks.browser_session_current
  end
end
