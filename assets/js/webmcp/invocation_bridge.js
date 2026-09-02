import {captureRoomState} from "./state_snapshot.js";
import {ExecutionAbortedError, waitForRevision} from "./revision_waiter.js";

const MAX_RESULT_LENGTH = 6000;
const MAX_SUMMARY_LENGTH = 200;
const MAX_DETAIL_LENGTH = 300;

export async function executeRevision(hook, revision, input, options = {}) {
  const signal = options.signal;

  if (signal?.aborted) return errorResult("EXECUTION_CANCELLED", "the call was cancelled before it started");
  if (!isCurrentRevision(hook, revision)) {
    return errorResult("REVISION_NOT_ACTIVE", "this tool revision is no longer the one the page offers");
  }

  const validationError = validateArguments(input);
  if (validationError) return errorResult("INVALID_ARGUMENTS", validationError);

  let begunInvocationId;
  let operationEpoch;

  try {
    const preState = await captureRoomState(hook.el?.ownerDocument ?? document);
    if (signal?.aborted) throw new ExecutionAbortedError();

    const requestUuid = createRequestUuid();
    operationEpoch = hook.invocationEpoch;
    const waiter = invocationResultWaiter(hook, requestUuid, signal);
    let start;
    try {
      const begin = await raceWithAbort(
        pushWithAck(hook, "webmcp_invocation_begin", {
          room_id: hook.roomId,
          browser_session_id: hook.browserSessionId,
          invocation_epoch: operationEpoch,
          request_uuid: requestUuid,
          tool_name: revision.name,
          contract_sha256: revision.contract_sha256,
          arguments: input,
          pre_state: preState,
        }),
        signal,
      );

      if (!begin || begin.error) {
        return errorResult("SERVER_REFUSED", begin?.error ?? "the server did not start the invocation");
      }

      if (begin.invocation_id) {
        begunInvocationId = begin.invocation_id;
        if (signal?.aborted) throw new ExecutionAbortedError();
        const execution = await raceWithAbort(
          pushWithAck(hook, "webmcp_execute", {
            invocation_id: begin.invocation_id,
            invocation_epoch: operationEpoch,
          }),
          signal,
        );

        if (!execution || execution.error) {
          cancelBegunInvocation(hook, begunInvocationId, operationEpoch);
          return errorResult("SERVER_REFUSED", execution?.error ?? "the server did not execute the invocation");
        }
        start = execution.ui_commit_required === undefined ? await waiter.promise : execution;
      } else {
        start = await waiter.promise;
      }
    } finally {
      waiter.cancel();
    }

    if (!start || start.error) {
      return errorResult("SERVER_REFUSED", start?.error ?? "the server did not finish the invocation");
    }
    if (!start.invocation_id) {
      return errorResult("SERVER_REFUSED", "the server did not return an invocation id");
    }

    return await completeInvocation(hook, start, options);
  } catch (error) {
    cancelBegunInvocation(hook, begunInvocationId, operationEpoch);

    if (error instanceof ExecutionAbortedError || error?.code === "EXECUTION_CANCELLED") {
      return errorResult("EXECUTION_CANCELLED", "the call was cancelled before visible proof completed");
    }
    if (error?.code === "UI_REVISION_TIMEOUT") {
      return errorResult("UI_REVISION_TIMEOUT", "the visible room did not commit the expected revision before the timeout");
    }
    return errorResult("INVOCATION_FAILED", error?.message ?? "the call failed before visible proof completed");
  }
}

function cancelBegunInvocation(hook, invocationId, invocationEpoch) {
  if (!invocationId) return;

  void pushWithAck(
    hook,
    "webmcp_invocation_cancel",
    {
      room_id: hook.roomId,
      browser_session_id: hook.browserSessionId,
      invocation_id: invocationId,
      invocation_epoch: invocationEpoch,
    },
    1000,
  ).catch(() => {});
}

function invocationResultWaiter(hook, requestUuid, signal) {
  hook.pendingInvocations ??= new Map();
  let settled = false;
  let timer;
  let onAbort;

  const cleanup = () => {
    clearTimeout(timer);
    if (onAbort) signal?.removeEventListener("abort", onAbort);
    if (hook.pendingInvocations.get(requestUuid)?.promise === promise) {
      hook.pendingInvocations.delete(requestUuid);
    }
  };

  let resolvePromise;
  let rejectPromise;
  const promise = new Promise((resolve, reject) => {
    resolvePromise = resolve;
    rejectPromise = reject;
  });
  const record = {
    promise,
    resolve(value) {
      if (settled) return;
      settled = true;
      cleanup();
      resolvePromise(value);
    },
    reject(error) {
      if (settled) return;
      settled = true;
      cleanup();
      rejectPromise(error);
    },
  };
  hook.pendingInvocations.set(requestUuid, record);
  timer = setTimeout(
    () => record.reject(new Error("the server did not finish the invocation in time")),
    30000,
  );
  onAbort = () => record.reject(new ExecutionAbortedError());
  signal?.addEventListener("abort", onAbort, {once: true});

  return {promise, cancel: cleanup};
}

export async function completeInvocation(hook, start, options = {}) {
  const signal = options.signal;
  if (!start?.invocation_id) {
    return errorResult("SERVER_REFUSED", "the server did not return an invocation id");
  }

  let revisionTimedOut = false;
  if (start.ui_commit_required) {
    try {
      await waitForRevision(hook.el?.ownerDocument ?? document, start.expected_ui_revision, {
        timeoutMs: options.revisionTimeoutMs ?? 2500,
        signal,
      });
    } catch (error) {
      if (error?.code !== "UI_REVISION_TIMEOUT") throw error;
      revisionTimedOut = true;
    }
  }

  if (signal?.aborted) throw new ExecutionAbortedError();
  const postState = await captureRoomState(hook.el?.ownerDocument ?? document);
  if (signal?.aborted) throw new ExecutionAbortedError();

  const verified = await raceWithAbort(
    pushWithAck(hook, "webmcp_poststate_observed", {
      room_id: hook.roomId,
      browser_session_id: hook.browserSessionId,
      invocation_epoch: hook.invocationEpoch,
      invocation_id: start.invocation_id,
      post_state: postState,
    }),
    signal,
  );

  if (!verified || verified.error) {
    return errorResult("PROOF_NOT_RECORDED", verified?.error ?? "the server could not record visible proof");
  }
  if (revisionTimedOut && verified.effective_status === "verified_success") {
    return errorResult(
      "UI_REVISION_TIMEOUT",
      "the server accepted proof before the expected UI revision appeared",
    );
  }
  return invocationResult(verified, start);
}

function invocationResult(verified, start) {
  const payload = {
    // One sentence naming the outcome, before any of the structure below.
    summary: invocationSummary(verified, start),
    reported_result: verified.handler_result ?? start.handler_result ?? null,
    // Proof this call happened, for quoting back when reporting it.
    patchbay_receipt: verified.patchbay_receipt ?? start.patchbay_receipt ?? null,
    report_this_call: verified.report_this_call ?? start.report_this_call ?? null,
    patchbay_verification: verified.patchbay_verification ?? null,
    effective_status: verified.effective_status ?? start.effective_status ?? "unknown",
    failure_code: verified.failure_code ?? null,
    next_action: verified.next_action ?? null,
  };
  const serialized = JSON.stringify(payload);
  if (serialized.length <= MAX_RESULT_LENGTH) return serialized;

  return JSON.stringify({
    summary: payload.summary,
    reported_result: payload.reported_result,
    patchbay_receipt: payload.patchbay_receipt,
    report_this_call: payload.report_this_call,
    patchbay_verification: {
      passed: payload.patchbay_verification?.passed ?? false,
      failure_code: payload.patchbay_verification?.failure_code ?? payload.failure_code,
      checks: payload.patchbay_verification?.checks ?? null,
      details_truncated: true,
    },
    effective_status: payload.effective_status,
    failure_code: payload.failure_code,
    next_action: payload.next_action,
  });
}

export function pushWithAck(hook, event, payload, timeoutMs) {
  if (hook.destroyedFlag || typeof hook.pushEvent !== "function") return Promise.resolve({});

  return new Promise((resolve, reject) => {
    let settled = false;
    const timer = setTimeout(
      () => finish(reject, new Error(`${event} did not receive a LiveView acknowledgement`)),
      timeoutMs ?? (event === "webmcp_invocation_begin" ? 30000 : (hook.pushTimeoutMs ?? 5000)),
    );
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      callback(value);
    };
    const onReply = reply => finish(resolve, reply ?? {});

    let returned;
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

export function validateArguments(input) {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    return "instructions must be an object with a non-empty string value";
  }

  const keys = Object.keys(input);
  if (keys.some(key => key !== "instructions")) return "only the instructions field is accepted";
  if (typeof input.instructions !== "string" || input.instructions.trim().length === 0) {
    return "instructions must be a non-empty string";
  }
  if (Array.from(input.instructions).length > 1000) {
    return "instructions must be 1000 characters or fewer";
  }
  return null;
}

/** One sentence naming what happened, for the front of every tool result. */
export function sentence(text, limit = MAX_SUMMARY_LENGTH) {
  const flat = String(text).replace(/\s+/g, " ").trim();
  return flat.length <= limit ? flat : `${flat.slice(0, limit - 1)}…`;
}

function invocationSummary(verified, start) {
  const status = verified.effective_status ?? start.effective_status ?? "unknown";
  const failureCode = verified.failure_code ?? null;

  if (status === "verified_success") {
    return sentence("The call ran and the visible room matched what the tool reported.");
  }
  if (status === "verified_failure") {
    return sentence(
      `The tool reported an outcome the visible room does not show${failureCode ? ` (${failureCode})` : ""}; the patchbay_receipt in this result is what report_tool_problem needs.`,
    );
  }
  return sentence(`The call finished with status ${status} and no visible proof yet.`);
}

/**
 * What an agent should do about each failure, so a refusal carries its own way
 * forward rather than only a name. Errors are shaped like successes: a summary
 * first, then structure.
 */
const ERROR_GUIDANCE = {
  BUSY: [true, "Wait for the call already in flight to finish, then read the page before calling again."],
  EXECUTION_CANCELLED: [true, "Call get_patchbay_room_state to read where the room got to, then call the tool again."],
  REVISION_NOT_ACTIVE: [true, "Call get_patchbay_room_state to read the active tool, then call that one."],
  INVALID_ARGUMENTS: [true, "Send one instructions field holding a non-empty string of at most 1000 characters."],
  UI_REVISION_TIMEOUT: [true, "Call verify_skill_uplift_goal to read what is visible, then call the tool again."],
  PROOF_NOT_RECORDED: [true, "Call verify_skill_uplift_goal to read what is visible, then call the tool again."],
  INVOCATION_FAILED: [true, "Call get_patchbay_room_state, then call the tool again."],
  SERVER_REFUSED: [false, "Call get_patchbay_room_state to read what the room reports about itself."],
  REPAIR_REQUEST_FAILED: [true, "Call get_patchbay_room_state to read the repair status, then ask again if none is running."],
};

/**
 * A failure in the same shape as a success: a summary sentence, then a code an
 * agent can branch on, the detail behind it, whether calling again could help,
 * and the one thing to do next.
 */
export function errorResult(errorCode, detail) {
  const [retryable, nextAction] = ERROR_GUIDANCE[errorCode];
  const flatDetail = sentence(detail, MAX_DETAIL_LENGTH);

  return JSON.stringify({
    summary: sentence(`This call did not complete: ${flatDetail}`),
    error_code: errorCode,
    detail: flatDetail,
    retryable,
    next_action: nextAction,
  });
}

/** The busy answer webmcpify hands back while a call is already in flight. */
export const BUSY_RESULT = errorResult(
  "BUSY",
  "a previous call to this tool is still in progress",
);

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
