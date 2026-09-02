defmodule Patchbay.Patchbay.PostconditionVerifier do
  @moduledoc """
  Pure visible-state verification for the seeded Skill Uplift postcondition set.

  The handler result is intentionally not treated as proof of completion. The
  verifier compares the browser snapshots and server-side evidence instead.
  """

  alias Patchbay.Patchbay.{Digest, Frontmatter}

  @checks [
    :candidate_present,
    :source_unchanged,
    :candidate_changed,
    :candidate_matches_server,
    :frontmatter_present,
    :frontmatter_parses,
    :identity_preserved,
    :ui_revision_advanced,
    :tool_contract_current,
    :browser_session_current
  ]

  @spec required_checks() :: [atom()]
  def required_checks, do: @checks

  @doc """
  Returns whether a verification result is a complete, internally consistent
  result from this verifier.
  """
  @spec valid_result?(map()) :: boolean()
  def valid_result?(%{
        passed: passed,
        checks: checks,
        failure_code: failure_code,
        expected_state: expected_state,
        observed_state: observed_state
      })
      when is_boolean(passed) do
    is_map(checks) and is_map(expected_state) and is_map(observed_state) and
      (not passed or complete_pass?(checks, failure_code, expected_state, observed_state))
  end

  def valid_result?(_), do: false

  # A recorded failure only has to be well formed. A recorded pass has to carry
  # the whole story: no failure code, both states captured, and every check
  # present and true.
  defp complete_pass?(checks, failure_code, expected_state, observed_state) do
    is_nil(failure_code) and map_size(expected_state) > 0 and map_size(observed_state) > 0 and
      checks_complete?(checks) and all_checks_true?(checks)
  end

  @doc "Returns whether all required checks in a result are present and true."
  @spec successful_result?(map()) :: boolean()
  def successful_result?(result) when is_map(result) do
    valid_result?(result) and result.passed == true
  end

  def successful_result?(_), do: false

  @spec verify(map(), map(), map() | keyword()) :: map()
  def verify(pre_state, post_state, opts \\ %{}) when is_map(pre_state) and is_map(post_state) do
    evidence = evidence(pre_state, post_state, Map.new(opts))
    checks = run_checks(evidence)
    failures = Enum.reject(@checks, &Map.get(checks, &1))

    %{
      passed: failures == [],
      checks: checks,
      failure_code: failure_code(failures),
      expected_state: pre_state,
      observed_state: post_state,
      source_sha256: evidence.source_sha256,
      candidate_sha256: evidence.candidate_sha256,
      pre_ui_revision: evidence.pre_revision,
      post_ui_revision: evidence.post_revision
    }
  end

  # Everything the checks compare, gathered once: what the room showed before
  # and after the call, and the server-side digests the observation is measured
  # against.
  defp evidence(pre_state, post_state, opts) do
    source = opts[:source_markdown]
    candidate = opts[:candidate_markdown]

    %{
      source: source,
      candidate: candidate,
      pre_candidate_state: state_for(pre_state, :candidate),
      candidate_state: state_for(post_state, :candidate),
      pre_revision: Map.get(pre_state, :ui_revision) || 0,
      post_revision: Map.get(post_state, :ui_revision) || 0,
      source_sha256: state_for(pre_state, :source)[:sha256] || digest_or_nil(source),
      post_source_sha256: state_for(post_state, :source)[:sha256] || digest_or_nil(source),
      candidate_sha256: digest_or_nil(candidate),
      observed_candidate_sha256: state_for(post_state, :candidate)[:sha256],
      expected_candidate_sha256: opts[:expected_candidate_sha256],
      expected_contract_sha256: opts[:expected_contract_sha256],
      observed_contract_sha256: opts[:observed_contract_sha256],
      expected_session_id: opts[:expected_browser_session_id],
      observed_session_id: opts[:observed_browser_session_id]
    }
  end

  defp run_checks(evidence) do
    %{
      candidate_present: candidate_present?(evidence),
      source_unchanged: source_unchanged?(evidence),
      candidate_changed: candidate_changed?(evidence),
      candidate_matches_server: candidate_matches_server?(evidence),
      frontmatter_present: starts_with_frontmatter?(evidence.candidate),
      frontmatter_parses: Frontmatter.valid?(evidence.candidate || ""),
      identity_preserved: identity_preserved?(evidence.source, evidence.candidate),
      ui_revision_advanced: ui_revision_advanced?(evidence),
      tool_contract_current:
        same_present_value?(evidence.expected_contract_sha256, evidence.observed_contract_sha256),
      browser_session_current:
        same_present_value?(evidence.expected_session_id, evidence.observed_session_id)
    }
  end

  defp candidate_present?(evidence),
    do: evidence.candidate_state[:present] == true and present?(evidence.candidate)

  defp source_unchanged?(evidence),
    do:
      present?(evidence.source_sha256) and
        evidence.source_sha256 == evidence.post_source_sha256

  defp candidate_changed?(evidence) do
    candidate_was_absent?(evidence.pre_candidate_state) and
      present?(evidence.candidate_sha256) and
      evidence.candidate_sha256 != evidence.source_sha256
  end

  defp candidate_matches_server?(evidence) do
    present?(evidence.candidate_sha256) and present?(evidence.observed_candidate_sha256) and
      present?(evidence.expected_candidate_sha256) and
      evidence.candidate_sha256 == evidence.observed_candidate_sha256 and
      evidence.candidate_sha256 == evidence.expected_candidate_sha256
  end

  defp ui_revision_advanced?(evidence) do
    is_integer(evidence.pre_revision) and is_integer(evidence.post_revision) and
      evidence.post_revision > evidence.pre_revision
  end

  # The contract digest and the session id are both checked the same way: the
  # server has to name one, the browser has to report one, and they have to be
  # the same one.
  defp same_present_value?(expected, observed),
    do: present?(expected) and present?(observed) and observed == expected

  @spec identity_preserved?(binary() | nil, binary() | nil) :: boolean()
  def identity_preserved?(source, candidate) when is_binary(source) and is_binary(candidate) do
    with {:ok, source_meta} <- Frontmatter.parse(source),
         {:ok, candidate_meta} <- Frontmatter.parse(candidate) do
      Enum.all?(~w(name license author), &same_identity_field?(source_meta, candidate_meta, &1))
    else
      _ -> false
    end
  end

  def identity_preserved?(_, _), do: false

  # A field the source never declared cannot have been lost, so only the ones it
  # declares are compared.
  defp same_identity_field?(source_meta, candidate_meta, key) do
    case Map.fetch(source_meta, key) do
      {:ok, value} -> Map.get(candidate_meta, key) == value
      :error -> true
    end
  end

  defp state_for(state, key) do
    case Map.get(state, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp starts_with_frontmatter?(value) when is_binary(value),
    do: String.starts_with?(value, "---")

  defp starts_with_frontmatter?(_), do: false

  defp digest_or_nil(value) when is_binary(value), do: Digest.sha256(value)
  defp digest_or_nil(_), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp candidate_was_absent?(candidate_state) do
    candidate_state[:present] == false and is_nil(candidate_state[:sha256])
  end

  defp checks_complete?(checks) do
    Enum.all?(@checks, &is_boolean(checks[&1]))
  end

  defp all_checks_true?(checks) do
    Enum.all?(@checks, &(checks[&1] == true))
  end

  defp failure_code([]), do: nil
  defp failure_code([:candidate_present | _]), do: :CANDIDATE_EMPTY
  defp failure_code([:source_unchanged | _]), do: :SOURCE_CHANGED_DURING_INVOCATION
  defp failure_code([:candidate_changed | _]), do: :CANDIDATE_DIGEST_MISMATCH
  defp failure_code([:candidate_matches_server | _]), do: :CANDIDATE_DIGEST_MISMATCH
  defp failure_code([:frontmatter_present | _]), do: :FRONTMATTER_INVALID
  defp failure_code([:frontmatter_parses | _]), do: :FRONTMATTER_INVALID
  defp failure_code([:identity_preserved | _]), do: :IDENTITY_NOT_PRESERVED
  defp failure_code([:ui_revision_advanced | _]), do: :UI_REVISION_NOT_APPLIED
  defp failure_code([:tool_contract_current | _]), do: :STALE_TOOL_REVISION
  defp failure_code([:browser_session_current | _]), do: :STALE_BROWSER_SESSION
end
