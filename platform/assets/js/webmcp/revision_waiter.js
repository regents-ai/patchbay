export class RevisionTimeoutError extends Error {
  constructor(expected, timeoutMs) {
    super(`The visible room did not reach UI revision ${expected} within ${timeoutMs}ms.`);
    this.name = "RevisionTimeoutError";
    this.code = "UI_REVISION_TIMEOUT";
  }
}

export class ExecutionAbortedError extends Error {
  constructor() {
    super("The WebMCP invocation was cancelled before visible proof completed.");
    this.name = "ExecutionAbortedError";
    this.code = "EXECUTION_CANCELLED";
  }
}

/** Wait for the exact server revision to be visible in the current document. */
export function waitForRevision(root, expected, options = {}) {
  const timeoutMs = options.timeoutMs ?? 2500;
  const signal = options.signal;
  const expectedRevision = Number(expected);

  return new Promise((resolve, reject) => {
    if (!Number.isFinite(expectedRevision)) {
      reject(new RevisionTimeoutError(expected, timeoutMs));
      return;
    }

    if (signal?.aborted) {
      reject(new ExecutionAbortedError());
      return;
    }

    const stateElement = root?.querySelector?.("#patchbay-room-state") ??
      document.querySelector?.("#patchbay-room-state");
    let settled = false;
    let timer;
    let poller;
    let observer;

    const finish = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      clearInterval(poller);
      observer?.disconnect?.();
      signal?.removeEventListener?.("abort", onAbort);
      if (error) reject(error); else resolve(true);
    };

    const currentRevision = () => {
      const value = Number(stateElement?.dataset?.uiRevision);
      return Number.isFinite(value) ? value : null;
    };

    const check = () => {
      if (signal?.aborted) return finish(new ExecutionAbortedError());
      if (currentRevision() === expectedRevision) {
        nextFrame(() => finish());
      }
    };

    const onAbort = () => finish(new ExecutionAbortedError());
    signal?.addEventListener?.("abort", onAbort, {once: true});

    const MutationObserverClass = globalThis.MutationObserver;
    if (MutationObserverClass && stateElement) {
      observer = new MutationObserverClass(check);
      observer.observe(stateElement, {attributes: true, attributeFilter: ["data-ui-revision"]});
    } else {
      // Test DOMs and older WebViews may not provide MutationObserver.
      poller = setInterval(check, 25);
    }
    timer = setTimeout(
      () => finish(new RevisionTimeoutError(expectedRevision, timeoutMs)),
      timeoutMs,
    );
    check();
  });
}

function nextFrame(callback) {
  if (typeof requestAnimationFrame === "function") requestAnimationFrame(callback);
  else setTimeout(callback, 0);
}
