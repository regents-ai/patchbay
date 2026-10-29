import {REVISION_ROW_NAME, prepareRoomRequest, executeRoomRequest} from "./room_signed.ts";
import {BUSY_RESULT, sentence} from "./invocation_bridge.ts";
import {verifyUpliftGoal} from "./goal_verifier.ts";
import {captureRoomState, readRoomMetadata, sha256Hex} from "./state_snapshot.ts";
import {singleFlight} from "./webmcpify.ts";
import {answered, bounded} from "./tool_result.ts";
import type {ToolResult} from "./tool_result.ts";
import type {BridgeHook, ExecuteOptions, ToolInput, ToolRevision} from "./invocation_bridge.ts";
import manifest from "../../../priv/tool_manifest.json" with {type: "json"};

export type PermanentToolsHook = BridgeHook & {
  siteOrigin?: string | null;
  desiredGeneration?: number;
  desiredRevisions?: Map<string, ToolRevision>;
};

type ToolFields = {name?: unknown; description?: unknown; inputSchema?: unknown; annotations?: unknown};

type Hints = {readOnlyHint: boolean; untrustedContentHint: boolean};

type ObservedHints = {readOnlyHint?: unknown; untrustedContentHint?: unknown} | null | undefined;

export type ToolContract = {name: unknown; description: unknown; inputSchema: unknown; annotations: Hints};

type RoomRow = {name: string; title: string; description: string; input_schema: unknown; annotations: Hints};

// The room page's tools are the manifest's rows scoped to room pages: their
// names, titles, descriptions, schemas and hints are read from there, and only
// the executors live here. One row is the room's current tool, which the page
// registers under the name of the generation the room offers now:
// uplift_current_skill_vN is uplift_current_skill_v1, then v2 after a repair.
const ROOM_ROWS = (manifest.tools as unknown as (RoomRow & {scope: string})[])
  .filter(tool => tool.scope === "page:/webmcp/rooms/*");
const REVISION_ROW = ROOM_ROWS.find(tool => tool.name === REVISION_ROW_NAME)!;
const REVISION_NAME = new RegExp(`^${REVISION_ROW_NAME.slice(0, -1)}\\d+$`);

/** The room tools the page registers whatever the room's current tool is called. */
export const PERMANENT_TOOL_NAMES = ROOM_ROWS.filter(tool => tool !== REVISION_ROW).map(tool => tool.name);

// A room read that is too large changed nothing; the room's page shows it all.
const ROOM_READ_HINT = "Nothing was changed. Read the room's state on its page.";

type RoomExecute = (input: ToolInput, options?: ExecuteOptions) => Promise<ToolResult>;

export function buildPermanentTools(hook: PermanentToolsHook) {
  const executors: Record<string, RoomExecute> = {
    get_patchbay_room_state: singleFlight(async () => {
      const state = await captureRoomState(hook.el?.ownerDocument ?? document);
      const metadata = readRoomMetadata(hook.el?.ownerDocument ?? document);
      return bounded(answered({
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
      }), 1200, ROOM_READ_HINT);
    }, BUSY_RESULT),
    verify_skill_uplift_goal: singleFlight(async () => {
      try {
        const verification = await verifyUpliftGoal(hook.el?.ownerDocument ?? document);
        return bounded(answered({summary: verificationSummary(verification), ...verification}), 1200, ROOM_READ_HINT);
      } catch (error) {
        // A verification that cannot run is reported in the same shape as one
        // that ran and failed, so the agent never has to parse a bare error.
        return bounded(answered({
          summary: "The visible room could not be verified, so nothing is claimed either way.",
          passed: false,
          checks: null,
          failure_code: "VERIFICATION_UNAVAILABLE",
          detail: sentence((error as {message?: unknown} | null | undefined)?.message ?? "the visible room could not be verified"),
          observed_generation: null,
          ui_revision: null,
        }), 1200, ROOM_READ_HINT);
      }
    }, BUSY_RESULT),
    // The raw body appears twice in the exact signing envelope. Preserve
    // it intact up to the site's 100 KB request bound, including escaping.
    prepare_patchbay_room_request: async (input: ToolInput) =>
      bounded(await prepareRoomRequest(hook, input), 512_000, "Nothing was prepared or sent. Shorten arguments_json."),
    request_patchbay_repair: (input, options = {}) => executeRoomRequest(hook, "request_patchbay_repair", input, options),
    finish_patchbay_room_call: (input, options = {}) => executeRoomRequest(hook, "finish_patchbay_room_call", input, options),
    cancel_patchbay_room_call: (input, options = {}) => executeRoomRequest(hook, "cancel_patchbay_room_call", input, options),
  };

  return ROOM_ROWS.filter(row => row !== REVISION_ROW).map(row => ({
    name: row.name,
    title: row.title,
    description: row.description,
    inputSchema: row.input_schema,
    annotations: row.annotations,
    execute: executors[row.name],
  }));
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
 * The room's current tool, under the name and title of the generation the room
 * offers now. Its own description leads; the manifest's row for it says how to
 * call it. Its schema and hints are the row's, and its original arguments are
 * in the revision's own schema, so the description does not repeat them.
 */
export function buildRevisionTool(hook: BridgeHook, revision: ToolRevision) {
  return {
    name: revision.name,
    title: revision.title ?? REVISION_ROW.title,
    description: `${revision.description} ${REVISION_ROW.description}`,
    inputSchema: REVISION_ROW.input_schema,
    annotations: REVISION_ROW.annotations,
    execute: singleFlight(
      (input: ToolInput, options: ExecuteOptions = {}) => executeRoomRequest(hook, REVISION_ROW_NAME, input, options),
      BUSY_RESULT,
    ),
  };
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

export function isPatchbayToolName(name: string) {
  return PERMANENT_TOOL_NAMES.includes(name) || REVISION_NAME.test(name);
}

export function stableStringify(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stableStringify((value as Record<string, unknown>)[key])}`).join(",")}}`;
}
