import {captureRoomState} from "./state_snapshot.js";
import {ExecutionAbortedError, waitForRevision} from "./revision_waiter.js";

const MAX_RESULT_LENGTH = 1400;

export async function executeRevision(hook, revision, input, options = {}) {
  const signal = options.signal;

  if (signal?.aborted) return errorResult("EXECUTION_CANCELLED: invocation was cancelled.");
  if (!isCurrentRevision(hook, revision)) {
    return errorResult("This tool revision is no longer active; inspect the current tools before retrying.");
  }

  const validationError = validateArguments(input);
  if (validationError) return errorResult(validationError);

  try {
    const preState = await captureRoomState(hook.el?.ownerDocument ?? document);
    if (signal?.aborted) throw new ExecutionAbortedError();

    const requestUuid = createRequestUuid();
    const start = await raceWithAbort(
      hook.pushEvent("webmcp_invocation_begin", {
        room_id: hook.roomId,
        browser_session_id: hook.browserSessionId,
        request_uuid: requestUuid,
        tool_name: revision.name,
        contract_sha256: revision.contract_sha256,
        arguments: input,
        pre_state: preState,
      }),
      signal,
    );

    if (!start || start.error) return errorResult(start?.error ?? "the server did not start the invocation");
    if (!start.invocation_id) return errorResult("the server did not return an invocation id");

    if (start.ui_commit_required) {
      await waitForRevision(hook.el?.ownerDocument ?? document, start.expected_ui_revision, {
        timeoutMs: options.revisionTimeoutMs ?? 2500,
        signal,
      });
    }

    if (signal?.aborted) throw new ExecutionAbortedError();
    const postState = await captureRoomState(hook.el?.ownerDocument ?? document);
    if (signal?.aborted) throw new ExecutionAbortedError();

    const verified = await raceWithAbort(
      hook.pushEvent("webmcp_poststate_observed", {
        room_id: hook.roomId,
        browser_session_id: hook.browserSessionId,
        invocation_id: start.invocation_id,
        post_state: postState,
      }),
      signal,
    );

    if (!verified || verified.error) return errorResult(verified?.error ?? "the server could not record visible proof");
    return statusResult(verified.effective_status ?? start.effective_status, verified.failure_code);
  } catch (error) {
    if (error instanceof ExecutionAbortedError || error?.code === "EXECUTION_CANCELLED") {
      return errorResult("EXECUTION_CANCELLED: invocation cancelled before visible proof completed.");
    }
    if (error?.code === "UI_REVISION_TIMEOUT") {
      return errorResult("UI_REVISION_TIMEOUT: the visible room did not commit the expected revision before the timeout.");
    }
    return errorResult(error?.message ?? "invocation failed before visible proof completed");
  }
}

export function validateArguments(input) {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    return "instructions must be an object with a non-empty string value";
  }

  const keys = Object.keys(input);
  if (keys.some(key => key !== "instructions")) return "only the instructions field is accepted";
  if (typeof input.instructions !== "string" || input.instructions.trim().length === 0) {
    return "instructions must be a non-empty string";
  }
  if (input.instructions.length > 1000) return "instructions must be 1000 characters or fewer";
  return null;
}

export function statusResult(status, failureCode) {
  const normalized = typeof status === "string" ? status : "unknown";
  const suffix = failureCode ? ` (${String(failureCode).slice(0, 180)})` : "";
  return `${normalized}${suffix}`.slice(0, MAX_RESULT_LENGTH);
}

export function errorResult(message) {
  return `ERROR: ${String(message).replace(/[\r\n]+/g, " ")}`.slice(0, MAX_RESULT_LENGTH);
}

export function raceWithAbort(promise, signal) {
  if (!signal) return Promise.resolve(promise);
  if (signal.aborted) return Promise.reject(new ExecutionAbortedError());

  return new Promise((resolve, reject) => {
    let settled = false;
    const onAbort = () => {
      if (settled) return;
      settled = true;
      reject(new ExecutionAbortedError());
    };
    signal.addEventListener("abort", onAbort, {once: true});
    Promise.resolve(promise).then(
      value => {
        if (settled) return;
        settled = true;
        signal.removeEventListener("abort", onAbort);
        resolve(value);
      },
      error => {
        if (settled) return;
        settled = true;
        signal.removeEventListener("abort", onAbort);
        reject(error);
      },
    );
  });
}

function isCurrentRevision(hook, revision) {
  if (typeof hook.isRevisionCurrent === "function") return hook.isRevisionCurrent(revision);
  return hook.activeRevision?.name === revision.name && hook.activeRevision?.contract_sha256 === revision.contract_sha256;
}

function createRequestUuid() {
  if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}
