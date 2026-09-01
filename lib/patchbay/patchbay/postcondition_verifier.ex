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
  Returns whether a persisted verification result is a complete, internally
  consistent result from this verifier.

  Persisted maps come back from PostgreSQL with string keys, so both atom and
  string keys are accepted when checking the result.
  """
  @spec valid_result?(map()) :: boolean()
  def valid_result?(result) when is_map(result) do
    checks = fetch(result, :checks, nil)
    expected_state = fetch(result, :expected_state, nil)
    observed_state = fetch(result, :observed_state, nil)
    passed = fetch(result, :passed, nil)
    failure_code = fetch(result, :failure_code, nil)

    is_boolean(passed) and is_map(checks) and is_map(expected_state) and
      is_map(observed_state) and
      (not passed or is_nil(failure_code)) and
      (not passed or
         (map_size(checks) > 0 and map_size(expected_state) > 0 and
            map_size(observed_state) > 0)) and
      (not passed or checks_complete?(checks)) and
      (not passed or all_checks_true?(checks))
  end

  def valid_result?(_), do: false

  @doc "Returns whether all required checks in a result are present and true."
  @spec successful_result?(map()) :: boolean()
  def successful_result?(result) when is_map(result) do
    valid_result?(result) and fetch(result, :passed, nil) == true
  end

  def successful_result?(_), do: false

  @doc "Returns whether a result's required checks are all present and true."
  @spec checks_passed?(map()) :: boolean()
  def checks_passed?(result) when is_map(result) do
    checks = fetch(result, :checks, nil)
    is_map(checks) and checks_complete?(checks) and all_checks_true?(checks)
  end

  def checks_passed?(_), do: false

  @spec verify(map()) :: map()
  def verify(%{} = envelope) do
    pre_state = fetch(envelope, :pre_state, %{})
    post_state = fetch(envelope, :post_state, %{})
    opts = Map.drop(envelope, [:pre_state, :post_state])
    verify(pre_state, post_state, opts)
  end

  @spec verify(map(), map(), map() | keyword()) :: map()
  def verify(pre_state, post_state, opts \\ %{}) when is_map(pre_state) and is_map(post_state) do
    opts = Map.new(opts)
    source = fetch(opts, :source_markdown, fetch(pre_state, :source_markdown, nil))
    candidate = fetch(opts, :candidate_markdown, fetch(post_state, :candidate_markdown, nil))
    source_state = state_for(pre_state, :source)
    pre_candidate_state = state_for(pre_state, :candidate)
    post_source_state = state_for(post_state, :source)
    candidate_state = state_for(post_state, :candidate)
    pre_revision = fetch(pre_state, :ui_revision, 0)
    post_revision = fetch(post_state, :ui_revision, 0)
    source_sha256 = fetch(source_state, :sha256, digest_or_nil(source))
    post_source_sha256 = fetch(post_source_state, :sha256, digest_or_nil(source))
    candidate_sha256 = digest_or_nil(candidate)
    observed_candidate_sha256 = fetch(candidate_state, :sha256, nil)
    expected_candidate_sha256 = fetch(opts, :expected_candidate_sha256, nil)
    expected_contract_sha256 = fetch(opts, :expected_contract_sha256, nil)
    observed_contract_sha256 = fetch(opts, :observed_contract_sha256, nil)
    expected_session_id = fetch(opts, :expected_browser_session_id, nil)
    observed_session_id = fetch(opts, :observed_browser_session_id, nil)

    checks = %{
      :candidate_present => fetch(candidate_state, :present, nil) == true and present?(candidate),
      :source_unchanged => present?(source_sha256) and source_sha256 == post_source_sha256,
      :candidate_changed =>
        candidate_was_absent?(pre_candidate_state) and present?(candidate_sha256) and
          candidate_sha256 != source_sha256,
      :candidate_matches_server =>
        present?(candidate_sha256) and present?(observed_candidate_sha256) and
          present?(expected_candidate_sha256) and candidate_sha256 == observed_candidate_sha256 and
          candidate_sha256 == expected_candidate_sha256,
      :frontmatter_present => starts_with_frontmatter?(candidate),
      :frontmatter_parses => Frontmatter.valid?(candidate || ""),
      :identity_preserved => identity_preserved?(source, candidate),
      :ui_revision_advanced =>
        is_integer(pre_revision) and is_integer(post_revision) and post_revision > pre_revision,
      :tool_contract_current =>
        present?(expected_contract_sha256) and present?(observed_contract_sha256) and
          observed_contract_sha256 == expected_contract_sha256,
      :browser_session_current =>
        present?(expected_session_id) and present?(observed_session_id) and
          observed_session_id == expected_session_id
    }

    failures = Enum.reject(@checks, &Map.get(checks, &1))

    %{
      passed: failures == [],
      checks: checks,
      failure_code: failure_code(failures),
      expected_state: pre_state,
      observed_state: post_state,
      source_sha256: source_sha256,
      candidate_sha256: candidate_sha256,
      pre_ui_revision: pre_revision,
      post_ui_revision: post_revision
    }
  end

  @spec identity_preserved?(binary() | nil, binary() | nil) :: boolean()
  def identity_preserved?(source, candidate) when is_binary(source) and is_binary(candidate) do
    with {:ok, source_meta} <- Frontmatter.parse(source),
         {:ok, candidate_meta} <- Frontmatter.parse(candidate) do
      Enum.all?(~w(name license author), fn key ->
        case Map.fetch(source_meta, key) do
          {:ok, value} -> Map.get(candidate_meta, key) == value
          :error -> true
        end
      end)
    else
      _ -> false
    end
  end

  def identity_preserved?(_, _), do: false

  defp state_for(state, key) do
    state
    |> fetch(key, %{})
    |> case do
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
    fetch(candidate_state, :present, nil) == false and
      is_nil(fetch(candidate_state, :sha256, nil))
  end

  defp checks_complete?(checks) do
    Enum.all?(@checks, fn check -> is_boolean(fetch(checks, check, nil)) end)
  end

  defp all_checks_true?(checks) do
    Enum.all?(@checks, fn check -> fetch(checks, check, false) == true end)
  end

  defp fetch(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

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
