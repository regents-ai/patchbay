import {BUSY_RESULT, errorResult, executeRevision, pushWithAck, sentence} from "./invocation_bridge.ts";
import {verifyUpliftGoal} from "./goal_verifier.ts";
import {captureRoomState, readRoomMetadata, sha256Hex} from "./state_snapshot.ts";
import {singleFlight} from "./webmcpify.ts";
import type {BridgeHook, ExecuteOptions, RoomReply, ToolInput, ToolRevision} from "./invocation_bridge.ts";

export type PermanentToolsHook = BridgeHook & {
  siteOrigin?: string | null;
  desiredGeneration?: number;
  desiredRevisions?: Map<string, ToolRevision>;
};

type ToolFields = {name?: unknown; description?: unknown; inputSchema?: unknown; annotations?: unknown};

type Hints = {readOnlyHint: boolean; untrustedContentHint: boolean};

type ObservedHints = {readOnlyHint?: unknown; untrustedContentHint?: unknown} | null | undefined;

export type ToolContract = {name: unknown; description: unknown; inputSchema: unknown; annotations: Hints};

export const PERMANENT_TOOL_NAMES = [
  "get_patchbay_room_state",
  "verify_skill_uplift_goal",
  "request_patchbay_repair",
];

/**
 * The one sentence every Patchbay tool description ends with. A description is
 * the only place an agent learns the loop this page is for, so each tool says
 * that results here are checked against the screen and names the way to report
 * a mismatch.
 */
export const VERIFIED_REPORTING_NOTE =
  "This page verifies tool results against what is visible on screen; a mismatch can be reported with report_tool_problem using the receipt from the result.";

export function withReportingNote(description: string) {
  return `${description} ${VERIFIED_REPORTING_NOTE}`;
}

const REPAIR_REQUEST_STATUSES: readonly unknown[] = [
  "repair_requested",
  "already_in_progress",
  "no_failed_invocation",
  "proposal_ready",
];

export function buildPermanentTools(hook: PermanentToolsHook) {
  return [
    {
      name: "get_patchbay_room_state",
      title: "Read Patchbay room state",
      description: withReportingNote("Read the active Patchbay goal, visible editor state, current tool generation, last verification, and whether an owner-approved repair is available."),
      inputSchema: emptySchema(),
      annotations: {readOnlyHint: true, untrustedContentHint: false},
      execute: singleFlight(async () => {
        const state = await captureRoomState(hook.el?.ownerDocument ?? document);
        const metadata = readRoomMetadata(hook.el?.ownerDocument ?? document);
        return boundedJson({
          summary: roomStateSummary(metadata),
          room: metadata.roomSlug,
          goal: "Place an improved candidate in the visible Candidate editor.",
          status: metadata.status,
          // The site this page files reports under, and the tool a report about
          // a call on this page will land on.
          origin: hook.siteOrigin ?? null,
          active_tool: activeTool(hook),
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
      }, BUSY_RESULT),
    },
    {
      name: "verify_skill_uplift_goal",
      title: "Verify the visible Skill uplift",
      description: withReportingNote("Verify whether the visible Candidate editor contains a structurally valid revision of the current Source Skill and whether the page-side goal was completed."),
      inputSchema: emptySchema(),
      annotations: {readOnlyHint: true, untrustedContentHint: true},
      execute: singleFlight(async () => {
        try {
          const verification = await verifyUpliftGoal(hook.el?.ownerDocument ?? document);
          return boundedJson({summary: verificationSummary(verification), ...verification});
        } catch (error) {
          // A verification that cannot run is reported in the same shape as one
          // that ran and failed, so the agent never has to parse a bare error.
          return boundedJson({
            summary: "The visible room could not be verified, so nothing is claimed either way.",
            passed: false,
            checks: null,
            failure_code: "VERIFICATION_UNAVAILABLE",
            detail: sentence((error as {message?: unknown} | null | undefined)?.message ?? "the visible room could not be verified"),
            observed_generation: null,
            ui_revision: null,
          });
        }
      }, BUSY_RESULT),
    },
    {
      name: "request_patchbay_repair",
      title: "Ask Patchbay to repair its broken tool",
      description: withReportingNote("Ask Patchbay to work out why its own tool failed on this page and propose a replacement. Approval and publication belong to the person at the page; this tool can only ask."),
      inputSchema: emptySchema(),
      annotations: {readOnlyHint: false, untrustedContentHint: true},
      execute: singleFlight(async () => {
        try {
          return repairRequestResult(await pushWithAck(hook, "webmcp_request_repair", {
            room_id: hook.roomId,
            browser_session_id: hook.browserSessionId,
          }));
        } catch (error) {
          return errorResult("REPAIR_REQUEST_FAILED", (error as {message?: unknown} | null | undefined)?.message ?? "the repair request was not answered");
        }
      }, BUSY_RESULT),
    },
  ];
}

function roomStateSummary(metadata: ReturnType<typeof readRoomMetadata>) {
  return sentence(
    `Room ${metadata.roomSlug} is ${metadata.status} at tool generation ${metadata.generation}, and ${lastVerification(metadata)}.`,
  );
}

function lastVerification(metadata: ReturnType<typeof readRoomMetadata>) {
  if (metadata.verificationPassed) return "its last verification passed";
  if (metadata.failureCode) return `its last verification failed with ${metadata.failureCode}`;
  return "nothing has been verified yet";
}

function verificationSummary(verification: {passed: boolean; failure_code: string | null}) {
  if (verification.passed) {
    return sentence("The visible room satisfies the uplift goal.");
  }
  return sentence(
    `The visible room does not satisfy the uplift goal (${verification.failure_code}).`,
  );
}

function activeTool(hook: PermanentToolsHook) {
  const [revision] = [...(hook.desiredRevisions?.values() ?? [])];
  if (!revision) return null;

  return {
    name: revision.name ?? null,
    contract_sha256: revision.contract_sha256 ?? null,
    generation: revision.generation ?? hook.desiredGeneration ?? null,
  };
}

/**
 * A repair request is only ever a request: whatever the room answers, the
 * result says this tool cannot publish a replacement. Publication happens
 * by the room's owner or by the Patchbay Agent, never from a tool call.
 */
function repairRequestResult(reply: RoomReply) {
  if (REPAIR_REQUEST_STATUSES.includes(reply?.status)) {
    return boundedJson({
      summary: sentence(
        `Patchbay answered the repair request with ${reply.status}; publishing a replacement is not something a tool can do.`,
      ),
      status: reply.status,
      detail: sentence(reply.detail ?? "", 300),
      tool_can_publish: false,
    });
  }
  return errorResult(
    "REPAIR_REQUEST_FAILED",
    reply?.error ?? "the room did not answer the repair request",
  );
}

export function buildRevisionTool(hook: BridgeHook, revision: ToolRevision) {
  const tool = {
    name: revision.name,
    title: revision.title,
    description: revision.description,
    inputSchema: revision.input_schema ?? revision.inputSchema ?? emptySchema(),
    annotations: revision.annotations ?? {readOnlyHint: false, untrustedContentHint: true},
    execute: singleFlight(
      (input: ToolInput, options: ExecuteOptions = {}) => executeRevision(hook, revision, input, options),
      BUSY_RESULT,
    ),
  };
  return tool;
}

const ANNOTATION_KEYS = ["readOnlyHint", "untrustedContentHint"] as const;

export function toolContract(tool: ToolFields | null | undefined): ToolContract {
  return {
    name: tool?.name ?? null,
    description: tool?.description ?? null,
    inputSchema: parseInputSchema(tool?.inputSchema),
    annotations: normalizeAnnotations(tool?.annotations),
  };
}

export async function toolContractDigest(tool: ToolFields | null | undefined) {
  return sha256Hex(stableStringify(toolContract(tool)));
}

/**
 * Digest a tool the browser enumerated so it can be held against the contract
 * Patchbay registered. Browsers are free to omit fields they do not model and to
 * canonicalize the ones they do, so only the fields the enumerated tool actually
 * carries are compared; anything else is filled in from the local registration
 * and named in `unverifiable`. A field a browser never reports is an observation
 * gap, not evidence that the contract changed.
 */
export async function observedContractDigest(observed: unknown, contract: ToolContract): Promise<{digest: string; unverifiable: string[]}> {
  const unverifiable: string[] = [];
  const effective = {
    name: contract.name,
    description: hasField(observed, "description") ? observed.description : missing(contract.description, "description", unverifiable),
    inputSchema: observedSchema(observed, contract, unverifiable),
    annotations: observedAnnotations(observed, contract, unverifiable),
  };
  return {digest: await sha256Hex(stableStringify(effective)), unverifiable};
}

function observedSchema(observed: unknown, contract: ToolContract, unverifiable: string[]) {
  if (!hasField(observed, "inputSchema")) return missing(contract.inputSchema, "inputSchema", unverifiable);

  const parsed = parseInputSchema(observed.inputSchema);
  if (parsed === null) return missing(contract.inputSchema, "inputSchema", unverifiable);
  return projectOntoContract(parsed, contract.inputSchema, unverifiable, "inputSchema");
}

function observedAnnotations(observed: unknown, contract: ToolContract, unverifiable: string[]) {
  if (!hasField(observed, "annotations") || !isPlainObject(observed.annotations)) {
    return missing(contract.annotations, "annotations", unverifiable);
  }

  const annotations: Record<string, boolean> = {};
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
function projectOntoContract(observed: unknown, contract: unknown, unverifiable: string[], path: string): unknown {
  if (isPlainObject(contract)) {
    if (!isPlainObject(observed)) return missing(contract, path, unverifiable);

    const projected: Record<string, unknown> = {};
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

function missing<T>(contractValue: T, path: string, unverifiable: string[]): T {
  unverifiable.push(path);
  return contractValue;
}

/**
 * A browser is free to expose an enumerated tool's fields as accessors on a
 * prototype, so presence is tested with `in` rather than own-property checks:
 * treating an inherited field as unreported would leave a replaced contract
 * looking healthy.
 */
function hasField<K extends string>(value: unknown, key: K): value is Record<K, unknown> {
  return value !== null && typeof value === "object" && key in value && (value as Record<K, unknown>)[key] !== undefined;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function parseInputSchema(inputSchema: unknown): unknown {
  if (typeof inputSchema !== "string") return inputSchema ?? null;
  try {
    const parsed: unknown = JSON.parse(inputSchema);
    return parsed ?? null;
  } catch {
    return null;
  }
}

function normalizeAnnotations(annotations: unknown): Hints {
  return {
    readOnlyHint: (annotations as ObservedHints)?.readOnlyHint === true,
    untrustedContentHint: (annotations as ObservedHints)?.untrustedContentHint === true,
  };
}

export function emptySchema() {
  return {type: "object", properties: {}, additionalProperties: false};
}

export function isPatchbayToolName(name: string) {
  return PERMANENT_TOOL_NAMES.includes(name) || /^uplift_current_skill_v\d+$/.test(name);
}

export function boundedJson(value: unknown, limit = 1100): string {
  let problemCode = "response_too_large";
  try {
    const exact = JSON.stringify(value);
    if (typeof exact !== "string") problemCode = "invalid_result";
    else if (new TextEncoder().encode(exact).byteLength <= limit) return exact;
  } catch {
    problemCode = "invalid_result";
  }
  const error = JSON.stringify({
    problem_code: problemCode,
    outcome: "unknown",
    error: "The result could not be returned intact. Check a write's status before retrying.",
  });
  if (new TextEncoder().encode(error).byteLength > limit) {
    throw new RangeError("The result limit must accommodate an error response.");
  }
  return error;
}

export function stableStringify(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stableStringify((value as Record<string, unknown>)[key])}`).join(",")}}`;
}
