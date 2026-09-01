import {executeRevision, pushWithAck} from "./invocation_bridge.js";
import {verifyUpliftGoal} from "./goal_verifier.js";
import {captureRoomState, readRoomMetadata, sha256Hex} from "./state_snapshot.js";
import {singleFlight} from "./webmcpify.js";

export const PERMANENT_TOOL_NAMES = [
  "get_patchbay_room_state",
  "verify_skill_uplift_goal",
  "request_patchbay_repair",
];

const REPAIR_REQUEST_STATUSES = [
  "repair_requested",
  "already_in_progress",
  "no_failed_invocation",
  "proposal_ready",
];

export function buildPermanentTools(hook) {
  return [
    {
      name: "get_patchbay_room_state",
      title: "Read Patchbay room state",
      description: "Read the active Patchbay goal, visible editor state, current tool generation, last verification, and whether an owner-approved repair is available.",
      inputSchema: emptySchema(),
      annotations: {readOnlyHint: true, untrustedContentHint: false},
      execute: singleFlight(async () => {
        const state = await captureRoomState(hook.el?.ownerDocument ?? document);
        const metadata = readRoomMetadata(hook.el?.ownerDocument ?? document);
        return boundedJson({
          room: metadata.roomSlug,
          goal: "Place an improved candidate in the visible Candidate editor.",
          status: metadata.status,
          desired_tool_generation: metadata.generation ?? hook.desiredGeneration,
          observed_tool_generation: metadata.observedGeneration,
          source_sha256: state.source.sha256,
          candidate_sha256: state.candidate.sha256,
          last_verification: {
            passed: metadata.verificationPassed,
            failure_code: metadata.failureCode,
          },
          repair: {
            status: metadata.repairStatus,
            owner_approved: metadata.repairApproved,
          },
        });
      }),
    },
    {
      name: "verify_skill_uplift_goal",
      title: "Verify the visible Skill uplift",
      description: "Verify whether the visible Candidate editor contains a structurally valid revision of the current Source Skill and whether the page-side goal was completed.",
      inputSchema: emptySchema(),
      annotations: {readOnlyHint: true, untrustedContentHint: true},
      execute: singleFlight(async () => {
        try {
          return boundedJson(await verifyUpliftGoal(hook.el?.ownerDocument ?? document));
        } catch (error) {
          // A verification that cannot run is reported in the same shape as one
          // that ran and failed, so the agent never has to parse a bare error.
          return boundedJson({
            passed: false,
            checks: null,
            failure_code: "VERIFICATION_UNAVAILABLE",
            detail: String(error?.message ?? "the visible room could not be verified").slice(0, 200),
            observed_generation: null,
            ui_revision: null,
          });
        }
      }),
    },
    {
      name: "request_patchbay_repair",
      title: "Ask Patchbay to repair its broken tool",
      description: "Ask Patchbay to work out why its own tool failed on this page and propose a replacement. Approval and publication belong to the person at the page; this tool can only ask.",
      inputSchema: emptySchema(),
      annotations: {readOnlyHint: false, untrustedContentHint: true},
      execute: singleFlight(async () => {
        try {
          return repairRequestResult(await pushWithAck(hook, "webmcp_request_repair", {
            room_id: hook.roomId,
            browser_session_id: hook.browserSessionId,
          }));
        } catch (error) {
          return repairRequestProblem(error?.message ?? "the repair request was not answered");
        }
      }),
    },
  ];
}

/**
 * A repair request is only ever a request: whatever the room answers, the
 * result says that a person still has to approve the replacement.
 */
function repairRequestResult(reply) {
  if (REPAIR_REQUEST_STATUSES.includes(reply?.status)) {
    return boundedJson({
      status: reply.status,
      detail: String(reply.detail ?? "").slice(0, 300),
      human_approval_required: true,
    });
  }
  return repairRequestProblem(reply?.error ?? "the room did not answer the repair request");
}

function repairRequestProblem(detail) {
  return boundedJson({
    error: String(detail).slice(0, 300),
    human_approval_required: true,
  });
}

export function buildRevisionTool(hook, revision) {
  const tool = {
    name: revision.name,
    title: revision.title,
    description: revision.description,
    inputSchema: revision.input_schema ?? revision.inputSchema ?? emptySchema(),
    annotations: revision.annotations ?? {readOnlyHint: false, untrustedContentHint: true},
    execute: singleFlight((input, options = {}) => executeRevision(hook, revision, input, options)),
  };
  return tool;
}

const ANNOTATION_KEYS = ["readOnlyHint", "untrustedContentHint"];

/** The fields of a tool that make up its contract, in a comparable shape. */
export function toolContract(tool) {
  return {
    name: tool?.name ?? null,
    description: tool?.description ?? null,
    inputSchema: parseInputSchema(tool?.inputSchema),
    annotations: normalizeAnnotations(tool?.annotations),
  };
}

export async function toolContractDigest(tool) {
  return sha256Hex(stableStringify(toolContract(tool)));
}

/**
 * Digest a tool the browser enumerated so it can be held against the contract
 * Patchbay registered. Browsers are free to omit fields they do not model and to
 * canonicalize the ones they do, so only the fields the enumerated tool actually
 * carries are compared; anything else is filled in from the local registration
 * and named in `unverifiable`. A field a browser never reports is an observation
 * gap, not evidence that the contract changed.
 *
 * @returns {Promise<{digest: string, unverifiable: string[]}>}
 */
export async function observedContractDigest(observed, contract) {
  const unverifiable = [];
  const effective = {
    name: contract.name,
    description: hasField(observed, "description") ? observed.description : missing(contract.description, "description", unverifiable),
    inputSchema: observedSchema(observed, contract, unverifiable),
    annotations: observedAnnotations(observed, contract, unverifiable),
  };
  return {digest: await sha256Hex(stableStringify(effective)), unverifiable};
}

function observedSchema(observed, contract, unverifiable) {
  if (!hasField(observed, "inputSchema")) return missing(contract.inputSchema, "inputSchema", unverifiable);

  const parsed = parseInputSchema(observed.inputSchema);
  if (parsed === null) return missing(contract.inputSchema, "inputSchema", unverifiable);
  return projectOntoContract(parsed, contract.inputSchema, unverifiable, "inputSchema");
}

function observedAnnotations(observed, contract, unverifiable) {
  if (!hasField(observed, "annotations") || !isPlainObject(observed.annotations)) {
    return missing(contract.annotations, "annotations", unverifiable);
  }

  const annotations = {};
  for (const key of ANNOTATION_KEYS) {
    annotations[key] = hasField(observed.annotations, key)
      ? observed.annotations[key] === true
      : missing(contract.annotations[key], `annotations.${key}`, unverifiable);
  }
  return annotations;
}

/**
 * Keep only what Patchbay itself declared: keys the browser added are ignored,
 * and keys it dropped are restored from the registered contract and recorded.
 */
function projectOntoContract(observed, contract, unverifiable, path) {
  if (isPlainObject(contract)) {
    if (!isPlainObject(observed)) return missing(contract, path, unverifiable);

    const projected = {};
    for (const key of Object.keys(contract)) {
      projected[key] = hasField(observed, key)
        ? projectOntoContract(observed[key], contract[key], unverifiable, `${path}.${key}`)
        : missing(contract[key], `${path}.${key}`, unverifiable);
    }
    return projected;
  }

  if (Array.isArray(contract) && !Array.isArray(observed)) return missing(contract, path, unverifiable);
  return observed;
}

function missing(contractValue, path, unverifiable) {
  unverifiable.push(path);
  return contractValue;
}

/**
 * A browser is free to expose an enumerated tool's fields as accessors on a
 * prototype, so presence is tested with `in` rather than own-property checks:
 * treating an inherited field as unreported would leave a replaced contract
 * looking healthy.
 */
function hasField(value, key) {
  return value !== null && typeof value === "object" && key in value && value[key] !== undefined;
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function parseInputSchema(inputSchema) {
  if (typeof inputSchema !== "string") return inputSchema ?? null;
  try {
    const parsed = JSON.parse(inputSchema);
    return parsed ?? null;
  } catch {
    return null;
  }
}

function normalizeAnnotations(annotations) {
  return {
    readOnlyHint: annotations?.readOnlyHint === true,
    untrustedContentHint: annotations?.untrustedContentHint === true,
  };
}

export function emptySchema() {
  return {type: "object", properties: {}, additionalProperties: false};
}

export function isPatchbayToolName(name) {
  return PERMANENT_TOOL_NAMES.includes(name) || /^uplift_current_skill_v\d+$/.test(name);
}

/**
 * Bound a tool result without ever handing the agent something it cannot parse:
 * oversized results keep their structure and lose only the tails of long text
 * values, flagged with `truncated: true`.
 */
export function boundedJson(value, limit = 1100) {
  const exact = serialize(value);
  if (exact !== null && exact.length <= limit) return exact;

  for (const maxTextLength of [256, 128, 64, 32, 16]) {
    const serialized = serialize(markTruncated(truncateText(value, maxTextLength)));
    if (serialized !== null && serialized.length <= limit) return serialized;
  }

  return JSON.stringify({truncated: true, error: "the result was too large to report"});
}

function serialize(value) {
  try {
    const serialized = JSON.stringify(value);
    return typeof serialized === "string" ? serialized : null;
  } catch {
    return null;
  }
}

function truncateText(value, maxTextLength) {
  if (typeof value === "string") {
    return value.length <= maxTextLength ? value : `${value.slice(0, maxTextLength)}…`;
  }
  if (Array.isArray(value)) return value.map(entry => truncateText(entry, maxTextLength));
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, entry]) => [key, truncateText(entry, maxTextLength)]),
    );
  }
  return value;
}

function markTruncated(value) {
  // Never overwrite a `truncated` field the result itself carries.
  if (isPlainObject(value) && !Object.hasOwn(value, "truncated")) return {...value, truncated: true};
  return {truncated: true, value};
}

export function stableStringify(value) {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(",")}}`;
}
