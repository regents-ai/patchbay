import {signedTransport} from "./agent_transport.ts";
import type {SignedInput} from "../../vendor/regent_agent_access/signed_tools";
import type {BridgeHook, ToolInput, ExecuteOptions} from "./invocation_bridge.ts";
import {captureRoomState, readRoomMetadata} from "./state_snapshot.ts";
import {waitForRevision} from "./revision_waiter.ts";
import manifest from "../../../priv/tool_manifest.json" with {type: "json"};

export function roomEnvelopeFor(name: string) {
  return manifest.tools.find(tool => tool.name === name)!.input_schema;
}
const operations: Record<string, string> = {invoke: "invoke_patchbay_room", observe: "finish_patchbay_room_invocation", cancel: "cancel_patchbay_room_invocation", repair: "request_patchbay_repair"};

export async function prepareRoomRequest(hook: BridgeHook, input: ToolInput) {
  const operation = operations[String(input.operation)];
  if (!operation || !hook.pageEvidence) throw new Error("Open the owner's room and wait for its tool registry. See /agents.md.");
  const metadata = readRoomMetadata(hook.el?.ownerDocument ?? document);
  if (!metadata.roomSlug) throw new Error("Room is unavailable");
  const body: Record<string, unknown> = {page_evidence: hook.pageEvidence};
  const requestInput: Record<string, unknown> = {slug: metadata.roomSlug};
  if (input.operation === "invoke") {
    const state = await captureRoomState(hook.el?.ownerDocument ?? document);
    const revision = [...(hook.desiredRevisions?.values() ?? [])].find(revision =>
      revision.generation === metadata.generation && hook.isRevisionCurrent?.(revision));
    if (!revision) throw new Error("Current tool is unavailable");
    Object.assign(body, {tool_name: revision.name, contract_sha256: revision.contract_sha256,
      request_uuid: input.request_uuid ?? crypto.randomUUID(),
      arguments: JSON.parse(String(input.arguments_json ?? "{}")), pre_state: visibleState(state)});
  }
  if (input.operation === "observe") {
    const state = await captureRoomState(hook.el?.ownerDocument ?? document);
    body.post_state = visibleState(state);
  }
  if (input.operation === "observe" || input.operation === "cancel") requestInput.invocation_id = input.invocation_id;
  requestInput.raw_body = JSON.stringify(body);
  return {ok: true, input: requestInput, request: signedTransport().prepare(operation, requestInput),
    next: "Sign this exact request with your existing SIWA signer, then call the corresponding room tool with input, request and proof."};
}

export async function executeRoomRequest(hook: BridgeHook, operation: string, input: ToolInput, options: ExecuteOptions = {}) {
  const response = await signedTransport().execute(operation, input as unknown as SignedInput, options.signal);
  const body = await response.json();
  if (!response.ok) return JSON.stringify(body);
  if (operation === "invoke_patchbay_room" && body.invocation_id) {
    // The second proof is prepared only after the actual editor has changed.
    // Nothing here signs automatically or substitutes a browser cookie.
    if (body.ui_commit_required) await waitForRevision(hook.el?.ownerDocument ?? document, body.expected_ui_revision, {signal: options.signal, timeoutMs: options.revisionTimeoutMs ?? 2500});
    const observation = await prepareRoomRequest(hook, {operation: "observe", invocation_id: body.invocation_id});
    return JSON.stringify({...body, verification: "not_recorded", observation});
  }
  return JSON.stringify(body);
}

function visibleState(state: Awaited<ReturnType<typeof captureRoomState>>) {
  return {ui_revision: state.ui_revision, source: {present: state.source.present, sha256: state.source.sha256},
    candidate: {present: state.candidate.present, sha256: state.candidate.sha256}};
}
