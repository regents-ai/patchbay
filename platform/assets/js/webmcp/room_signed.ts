import {signedTransport} from "./agent_transport.ts";
import type {SignedInput} from "../../vendor/regent_agent_access/signed_tools.ts";
import type {BridgeHook, ToolInput, ExecuteOptions} from "./invocation_bridge.ts";
import {captureRoomState, readRoomMetadata} from "./state_snapshot.ts";
import {waitForRevision} from "./revision_waiter.ts";
import {answered, refusedWith} from "./tool_result.ts";
import type {ToolResult} from "./tool_result.ts";

/**
 * The manifest row of the room's current tool. The page registers it as
 * uplift_current_skill_v<generation>; signed, it is this one operation.
 */
export const REVISION_ROW_NAME = "uplift_current_skill_vN";

const operations: Record<string, string> = {invoke: REVISION_ROW_NAME, observe: "finish_patchbay_room_call", cancel: "cancel_patchbay_room_call", repair: "request_patchbay_repair"};

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
  return {ok: true as const, input: requestInput, request: signedTransport().prepare(operation, requestInput),
    next: "Sign this exact request with your existing SIWA signer, then call the corresponding room tool with input, request and proof."};
}

export async function executeRoomRequest(hook: BridgeHook, operation: string, input: ToolInput, options: ExecuteOptions = {}): Promise<ToolResult> {
  const response = await signedTransport().execute(operation, input as unknown as SignedInput, options.signal);
  const body = await response.json();
  if (!response.ok) return refusedWith(body.error, response.status);
  if (operation === REVISION_ROW_NAME && body.invocation_id) {
    // The second proof is prepared only after the actual editor has changed.
    // Nothing here signs automatically or substitutes a browser cookie.
    // An editor that misses the timeout is observed as it stands, so the
    // server's verifier records the visible failure against this call.
    if (body.ui_commit_required) {
      await waitForRevision(hook.el?.ownerDocument ?? document, body.expected_ui_revision, {signal: options.signal, timeoutMs: options.revisionTimeoutMs ?? 2500})
        .catch(error => { if (error?.code !== "UI_REVISION_TIMEOUT") throw error; });
    }
    const observation = await prepareRoomRequest(hook, {operation: "observe", invocation_id: body.invocation_id});
    return answered({...body, verification: "not_recorded", observation}, response.status);
  }
  return answered(body, response.status);
}

function visibleState(state: Awaited<ReturnType<typeof captureRoomState>>) {
  return {ui_revision: state.ui_revision, source: {present: state.source.present, sha256: state.source.sha256},
    candidate: {present: state.candidate.present, sha256: state.candidate.sha256}};
}
