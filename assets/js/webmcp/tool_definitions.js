import {executeRevision, errorResult} from "./invocation_bridge.js";
import {captureRoomState, readRoomMetadata, sha256Hex} from "./state_snapshot.js";
import {singleFlight} from "./webmcpify.js";

export const PERMANENT_TOOL_NAMES = [
  "get_patchbay_room_state",
  "verify_skill_uplift_goal",
];

export function buildPermanentTools(hook) {
  return [
    {
      name: "get_patchbay_room_state",
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
      description: "Verify whether the visible Candidate editor contains a structurally valid revision of the current Source Skill and whether the page-side goal was completed.",
      inputSchema: emptySchema(),
      annotations: {readOnlyHint: true, untrustedContentHint: true},
      execute: singleFlight(async () => {
        const state = await captureRoomState(hook.el?.ownerDocument ?? document);
        const metadata = readRoomMetadata(hook.el?.ownerDocument ?? document);
        const passed = metadata.status === "verified";

        if (!passed) {
          return errorResult("the visible goal is not verified yet; inspect the room evidence and retry after approval");
        }
        return boundedJson({
          passed: true,
          status: metadata.status,
          candidate: state.candidate,
          last_verification: {
            passed: metadata.verificationPassed,
            failure_code: metadata.failureCode,
          },
        });
      }),
    },
  ];
}

export function buildRevisionTool(hook, revision) {
  const tool = {
    name: revision.name,
    description: revision.description,
    inputSchema: revision.input_schema ?? revision.inputSchema ?? emptySchema(),
    annotations: revision.annotations ?? {readOnlyHint: false, untrustedContentHint: true},
    execute: singleFlight((input, options = {}) => executeRevision(hook, revision, input, options)),
  };
  return tool;
}

export async function toolContractDigest(tool) {
  return sha256Hex(stableStringify({
    name: tool.name,
    description: tool.description,
    inputSchema: tool.inputSchema,
    annotations: tool.annotations,
  }));
}

export function emptySchema() {
  return {type: "object", properties: {}, additionalProperties: false};
}

export function isPatchbayToolName(name) {
  return PERMANENT_TOOL_NAMES.includes(name) || /^uplift_current_skill_v\d+$/.test(name);
}

export function boundedJson(value, limit = 1100) {
  let serialized;
  try {
    serialized = JSON.stringify(value);
  } catch {
    serialized = "{}";
  }
  return serialized.length <= limit ? serialized : `${serialized.slice(0, limit - 1)}…`;
}

export function stableStringify(value) {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(",")}}`;
}
