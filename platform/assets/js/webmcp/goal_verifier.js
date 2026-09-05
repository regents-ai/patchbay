import {byteLength, captureRoomState, readRoomMetadata, readVisibleText} from "./state_snapshot.js";

const MAX_FRONTMATTER_BYTES = 8192;
const KEY_PATTERN = /^[-A-Za-z0-9_]+$/;

/**
 * Structural verification of the visible room, mirroring the server's
 * `skill_candidate_written_v1` postcondition set. Everything here is read from
 * the DOM the person can see: the tool must never report a pass on the strength
 * of a status label or of text the model itself produced.
 */
export async function verifyUpliftGoal(root = document) {
  const state = await captureRoomState(root);
  const metadata = readRoomMetadata(root);
  const source = readVisibleText(root, "#patchbay-source-editor");
  const candidate = readVisibleText(root, "#patchbay-candidate-editor");
  const parsedCandidate = parseFrontmatter(candidate);
  const parsedSource = parseFrontmatter(source);
  const sourceName = parsedSource.metadata?.name ?? null;

  const checks = {
    candidate_present: candidate.trim().length > 0,
    frontmatter_present: parsedCandidate.delimited,
    frontmatter_parses: parsedCandidate.metadata !== null,
    source_identity_readable: typeof sourceName === "string" && sourceName.length > 0,
    identity_preserved:
      typeof sourceName === "string" &&
      sourceName.length > 0 &&
      parsedCandidate.metadata?.name === sourceName,
    candidate_changed: candidate !== source,
    candidate_matches_server:
      typeof state.candidate.sha256 === "string" &&
      state.candidate.sha256 === metadata.candidateSha256,
  };

  const failureCode = firstFailureCode(checks);

  return {
    passed: failureCode === null,
    checks,
    failure_code: failureCode,
    frontmatter_reason: parsedCandidate.reason,
    source_frontmatter_reason: parsedSource.reason ?? (checks.source_identity_readable ? null : "frontmatter_name_missing"),
    observed_generation: metadata.observedGeneration,
    ui_revision: state.ui_revision,
  };
}

function firstFailureCode(checks) {
  if (!checks.candidate_present) return "CANDIDATE_EMPTY";
  if (!checks.frontmatter_present || !checks.frontmatter_parses) return "FRONTMATTER_INVALID";
  // An unreadable Source is a room problem, not a fault in the candidate: the
  // identity it should have preserved cannot be established either way.
  if (!checks.source_identity_readable) return "SOURCE_FRONTMATTER_INVALID";
  if (!checks.identity_preserved) return "IDENTITY_NOT_PRESERVED";
  if (!checks.candidate_changed) return "VISIBLE_POSTCONDITION_NOT_MET";
  if (!checks.candidate_matches_server) return "CANDIDATE_DIGEST_MISMATCH";
  return null;
}

/**
 * Bounded parser for the string-valued frontmatter the demo Skill uses. It is
 * deliberately not a YAML implementation: candidate text is untrusted data, so
 * only `key: value` lines are recognised and nothing is evaluated.
 *
 * @returns {{delimited: boolean, metadata: Record<string, string> | null, reason: string | null}}
 */
export function parseFrontmatter(markdown) {
  const text = typeof markdown === "string" ? markdown : "";
  const opening = /^---\r?\n/.exec(text);
  if (!opening) return {delimited: false, metadata: null, reason: "frontmatter_missing_start"};

  const rest = text.slice(opening[0].length);
  const closing = /\r?\n---(\r?\n|$)/.exec(rest);
  if (!closing) return {delimited: false, metadata: null, reason: "frontmatter_missing_end"};

  const block = rest.slice(0, closing.index);
  if (byteLength(block) > MAX_FRONTMATTER_BYTES) {
    return {delimited: true, metadata: null, reason: "frontmatter_too_large"};
  }

  const metadata = {};
  for (const line of block.split(/\r?\n/)) {
    if (line.trim() === "" || line.startsWith("#")) continue;
    if (/^[ \t]/.test(line)) return {delimited: true, metadata: null, reason: "frontmatter_nested"};

    const separator = line.indexOf(":");
    if (separator === -1) return {delimited: true, metadata: null, reason: "frontmatter_line_invalid"};

    const key = line.slice(0, separator).trim();
    if (!KEY_PATTERN.test(key)) return {delimited: true, metadata: null, reason: "frontmatter_key_invalid"};
    if (Object.prototype.hasOwnProperty.call(metadata, key)) {
      return {delimited: true, metadata: null, reason: "frontmatter_duplicate_key"};
    }

    const value = parseValue(line.slice(separator + 1).trim());
    if (value === null) return {delimited: true, metadata: null, reason: "frontmatter_unterminated_quote"};
    metadata[key] = value;
  }

  return {delimited: true, metadata, reason: null};
}

function parseValue(value) {
  for (const quote of ['"', "'"]) {
    if (!value.startsWith(quote)) continue;
    const body = value.slice(1);
    return body.endsWith(quote) && body.length >= 1 ? body.slice(0, -1) : null;
  }
  return value;
}
