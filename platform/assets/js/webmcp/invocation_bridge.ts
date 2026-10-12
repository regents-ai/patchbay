import {refusal} from "../api_error.ts";
import {captureRoomState} from "./state_snapshot.ts";
import {ExecutionAbortedError, waitForRevision} from "./revision_waiter.ts";

const MAX_SUMMARY_LENGTH = 200;

/** What the room's LiveView answers or pushes: JSON, read one field at a time. */
export type RoomReply = {[field: string]: unknown};

/** The arguments an agent passes to a tool. */
export type ToolInput = {[field: string]: unknown};

/** A tool revision as the room publishes it. */
export interface ToolRevision {
  name: string;
  contract_sha256: string;
  generation?: number;
  title?: string;
  description?: string;
  input_schema?: unknown;
  inputSchema?: unknown;
  annotations?: unknown;
}

export type PushEvent = (
  event: string,
  payload: unknown,
  onReply: (reply: RoomReply | undefined) => void,
) => PromiseLike<RoomReply | undefined> | void;

/** The parts of the room's LiveView hook the bridge reads and writes. */
export interface BridgeHook {
  el?: {ownerDocument: Document | null} | null;
  roomId: unknown;
  pageEvidence?: string;
  browserSessionId: unknown;
  invocationEpoch: number;
  destroyedFlag?: boolean;
  pushTimeoutMs?: number;
  pushEvent: PushEvent;
  isRevisionCurrent?: (revision: ToolRevision) => boolean;
  desiredRevisions?: Map<string, ToolRevision>;
}

export interface ExecuteOptions {
  signal?: AbortSignal;
  revisionTimeoutMs?: number;
}

/**
 * Reports what the room shows after the owner's own retry. The page waits for
 * the editor to commit the retried call, then hands its visible state to the
 * server, whose verifier records the outcome on the room.
 */
export async function reportRetry(hook: BridgeHook, retry: RoomReply, signal: AbortSignal): Promise<RoomReply> {
  const root = hook.el?.ownerDocument ?? document;
  if (retry.ui_commit_required) {
    await waitForRevision(root, retry.expected_ui_revision, {timeoutMs: 2500, signal})
      .catch(error => { if (error?.code !== "UI_REVISION_TIMEOUT") throw error; });
  }
  const postState = await captureRoomState(root);
  if (signal.aborted) throw new ExecutionAbortedError();

  return pushWithAck(hook, "webmcp_poststate_observed", {
    room_id: hook.roomId,
    browser_session_id: hook.browserSessionId,
    invocation_epoch: hook.invocationEpoch,
    invocation_id: retry.invocation_id,
    post_state: postState,
  });
}

export function pushWithAck(hook: BridgeHook, event: string, payload: unknown, timeoutMs?: number): Promise<RoomReply> {
  if (hook.destroyedFlag || typeof hook.pushEvent !== "function") return Promise.resolve({});

  return new Promise<RoomReply>((resolve, reject) => {
    let settled = false;
    const timer = setTimeout(
      () => finish(reject, new Error(`${event} did not receive a LiveView acknowledgement`)),
      timeoutMs ?? hook.pushTimeoutMs ?? 5000,
    );
    const finish = <T>(callback: (value: T) => void, value: T) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      callback(value);
    };
    const onReply = (reply: RoomReply | undefined) => finish(resolve, reply ?? {});

    let returned: ReturnType<PushEvent>;
    try {
      returned = hook.pushEvent(event, payload, onReply);
    } catch (error) {
      finish(reject, error);
      return;
    }
    if (returned && typeof returned.then === "function") {
      returned.then(value => finish(resolve, value ?? {}), error => finish(reject, error));
    }
  });
}

/** One sentence naming what happened, for the front of every tool result. */
export function sentence(text: unknown, limit = MAX_SUMMARY_LENGTH): string {
  const flat = String(text).replace(/\s+/g, " ").trim();
  return flat.length <= limit ? flat : `${flat.slice(0, limit - 1)}…`;
}

/** The busy answer webmcpify hands back while a call is already in flight. */
export const BUSY_RESULT = JSON.stringify(refusal(
  "BUSY",
  "This call did not complete: a previous call to this tool is still in progress",
  "Wait for the call already in flight to finish, then read the page before calling again.",
  {detail: "a previous call to this tool is still in progress", retryable: true},
));
