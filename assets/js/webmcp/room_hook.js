import {
  buildPermanentTools,
  buildRevisionTool,
  isPatchbayToolName,
  toolContractDigest,
} from "./tool_definitions.js";
import {createToolScope, getModelContext} from "./webmcpify.js";
import {completeInvocation, pushWithAck} from "./invocation_bridge.js";
import {readRoomMetadata, sha256Hex} from "./state_snapshot.js";

const SESSION_KEY_PREFIX = "patchbay:webmcp:client:";

const PatchbayWebMCP = {
  async mounted() {
    initialise(this);
    this.handleEvent(`${eventPrefix(this)}:desired_toolset`, payload => {
      void enqueue(this, () => reconcile(this, payload));
    });
    this.handleEvent(`${eventPrefix(this)}:publication_requested`, payload => {
      if (payload?.revision) {
        void enqueue(this, () => reconcile(this, {
          room_id: payload.room_id,
          generation: payload.revision.generation,
          revisions: [payload.revision],
        }));
      }
    });
    this.handleEvent(`${eventPrefix(this)}:reset_browser_registry`, payload => {
      if (payload?.room_id && payload.room_id !== this.roomId) return;
      this.invocationEpoch = Number.isInteger(payload?.invocation_epoch)
        ? payload.invocation_epoch
        : this.invocationEpoch + 1;
      abortInvocationWork(this, "Patchbay reset before invocation completion");
      retireAllRevisions(this);
      this.registryReady = false;
      setCapability(this, "connecting");
    });
    this.handleEvent(`${eventPrefix(this)}:ui_retry_started`, payload => {
      if (payload?.invocation_epoch !== this.invocationEpoch) return;
      const controller = new AbortController();
      this.retryControllers.add(controller);
      void completeInvocation(this, payload, {signal: controller.signal})
        .catch(error => {
          if (!this.destroyedFlag && !controller.signal.aborted) {
            setCapability(this, "error", error?.message);
          }
        })
        .finally(() => this.retryControllers.delete(controller));
    });
    this.handleEvent(`${eventPrefix(this)}:invocation_result`, payload => {
      if (payload?.invocation_epoch !== this.invocationEpoch) return;
      this.pendingInvocations?.get(payload?.request_uuid)?.resolve(payload);
    });

    if (this.modelContext?.addEventListener) {
      this.modelContext.addEventListener("toolchange", this.onToolChange);
    }
    await bootstrap(this);
  },

  async reconnected() {
    invalidateBootstrap(this);
    await bootstrap(this);
  },

  disconnected() {
    if (this.destroyedFlag) return;
    const browserSessionId = this.browserSessionId;
    abortInvocationWork(this, "WebMCP disconnected before invocation completion");
    invalidateBootstrap(this);
    if (!browserSessionId) return;
    void push(this, "webmcp_session_disconnected", {
      room_id: this.roomId,
      browser_session_id: browserSessionId,
    }).catch(() => {});
  },

  destroyed() {
    this.destroyedFlag = true;
    this.lifecycle += 1;
    this.onToolChange?.abort?.();
    this.modelContext?.removeEventListener?.("toolchange", this.onToolChange);
    retireAllRevisions(this);
    abortInvocationWork(this, "WebMCP hook was destroyed before invocation completion");
    this.permanentScope?.();
    this.permanentScope = null;
  },
};

export {PatchbayWebMCP};

export function initialise(hook) {
  hook.roomId = hook.el?.dataset?.roomId ?? null;
  hook.modelContext = getModelContext();
  hook.browserSessionId = null;
  hook.clientInstanceId = loadClientInstanceId(hook.roomId);
  hook.desiredGeneration = 1;
  hook.controllers = new Map();
  hook.registeredDigests = new Map();
  hook.pendingRegistrations = new Map();
  hook.permanentScope = null;
  hook.destroyedFlag = false;
  hook.lifecycle = 0;
  hook.reconcileQueue = Promise.resolve();
  hook.reconcileEpoch = 0;
  hook.desiredRevisions = new Map();
  hook.pendingDesired = null;
  hook.pendingInvocations = new Map();
  hook.retryControllers = new Set();
  hook.invocationEpoch = 0;
  hook.bootstrapped = false;
  hook.bootstrapping = false;
  hook.registryReady = false;
  hook.reconciling = false;
  hook.toolchangePending = false;
  hook.isRevisionCurrent = revision => {
    const active = hook.controllers.get(revision?.name);
    return active?.digest === revision?.contract_sha256 &&
      hook.desiredRevisions.get(revision?.name)?.contract_sha256 === revision?.contract_sha256;
  };
  hook.onToolChange = () => {
    if (hook.destroyedFlag || !hook.modelContext) return;
    if (!hook.registryReady || hook.reconciling) {
      hook.toolchangePending = true;
      return;
    }
    void reportToolChange(hook).catch(error => {
      if (!hook.destroyedFlag) setCapability(hook, "error", error?.message);
    });
  };
  setCapability(hook, hook.modelContext ? "connecting" : "unsupported");
}

export async function bootstrap(hook) {
  if (hook.destroyedFlag) return;
  if (hook.bootstrapPromise) return hook.bootstrapPromise;

  const lifecycle = hook.lifecycle;
  hook.bootstrapping = true;
  const attempt = (async () => {
    hook.modelContext = getModelContext();
    if (!hook.modelContext || typeof hook.modelContext.registerTool !== "function") {
      setCapability(hook, "unsupported");
      await push(hook, "webmcp_bootstrap", {
        room_id: hook.roomId,
        client_instance_id: hook.clientInstanceId,
        webmcp_supported: false,
        user_agent_digest: await digestUserAgent(),
      });
      hook.bootstrapping = false;
      return;
    }

    setCapability(hook, "connecting");
    const reply = await push(hook, "webmcp_bootstrap", {
      room_id: hook.roomId,
      client_instance_id: hook.clientInstanceId,
      webmcp_supported: true,
      user_agent_digest: await digestUserAgent(),
    });
    if (hook.destroyedFlag || lifecycle !== hook.lifecycle) return;
    if (reply?.error) {
      hook.bootstrapping = false;
      setCapability(hook, "error", reply.error);
      return;
    }
    hook.browserSessionId = reply?.browser_session_id ?? hook.browserSessionId;
    if (Number.isInteger(reply?.invocation_epoch)) hook.invocationEpoch = reply.invocation_epoch;
    if (Number.isInteger(reply?.desired_generation)) hook.desiredGeneration = reply.desired_generation;
    if (!hook.permanentScope) {
      const ready = await registerPermanentTools(hook, lifecycle);
      if (!ready) throw new Error("required Patchbay tools did not register");
    }
    if (hook.destroyedFlag || lifecycle !== hook.lifecycle) return;
    const desired = hook.pendingDesired ?? {
      room_id: hook.roomId,
      generation: hook.desiredGeneration,
      revisions: Array.isArray(reply?.revisions) ? reply.revisions : [],
    };
    hook.pendingDesired = null;
    hook.bootstrapping = false;
    await reconcile(hook, desired, lifecycle);
    if (hook.destroyedFlag || lifecycle !== hook.lifecycle) return;
    hook.bootstrapped = true;
    setCapability(hook, "connected");
  })().catch(error => {
    if (!hook.destroyedFlag && lifecycle === hook.lifecycle) {
      setCapability(hook, "error", error?.message);
      hook.bootstrapping = false;
    }
  }).finally(() => {
    if (hook.bootstrapPromise === attempt) hook.bootstrapPromise = null;
  });
  hook.bootstrapPromise = attempt;
  return hook.bootstrapPromise;
}

function invalidateBootstrap(hook) {
  const unfinishedBootstrap = hook.bootstrapping && !hook.bootstrapped;
  hook.lifecycle += 1;
  hook.reconcileEpoch += 1;
  hook.reconciling = false;
  hook.registryReady = false;
  hook.bootstrapping = false;
  hook.bootstrapPromise = null;
  if (unfinishedBootstrap && hook.permanentScope) {
    hook.permanentScope();
    hook.permanentScope = null;
    hook.registeredDigests.delete("get_patchbay_room_state");
    hook.registeredDigests.delete("verify_skill_uplift_goal");
  }
}

async function registerPermanentTools(hook, lifecycle) {
  const tools = buildPermanentTools(hook);
  const scope = createToolScope(`patchbay:${hook.roomId}:permanent`, tools, {
    validate: true,
    onError: error => setCapability(hook, "error", error?.message),
  });
  hook.permanentScope = scope;
  const ready = await scope.ready;
  if (!ready || hook.destroyedFlag || lifecycle !== hook.lifecycle) {
    scope();
    if (hook.permanentScope === scope) hook.permanentScope = null;
    return false;
  }

  for (const tool of tools) {
    hook.registeredDigests.set(tool.name, await toolContractDigest(tool));
    if (hook.destroyedFlag || lifecycle !== hook.lifecycle) return false;
  }
  for (const tool of tools) {
    await push(hook, "webmcp_tool_registered", {
      room_id: hook.roomId,
      browser_session_id: hook.browserSessionId,
      tool_name: tool.name,
      generation: hook.desiredGeneration,
      contract_sha256: hook.registeredDigests.get(tool.name),
    });
    if (hook.destroyedFlag || lifecycle !== hook.lifecycle) return false;
  }
  return true;
}

export function enqueue(hook, operation) {
  const lifecycle = hook.lifecycle;
  const runIfCurrent = () => lifecycle === hook.lifecycle ? operation() : undefined;
  hook.reconcileQueue = hook.reconcileQueue.then(runIfCurrent, runIfCurrent).catch(error => {
    if (!hook.destroyedFlag && lifecycle === hook.lifecycle) {
      hook.reconciling = false;
      hook.registryReady = false;
      setCapability(hook, "error", error?.message);
    }
  });
  return hook.reconcileQueue;
}

export async function reconcile(hook, payload = {}, expectedLifecycle = hook.lifecycle) {
  if (hook.destroyedFlag || (payload.room_id && payload.room_id !== hook.roomId)) return;
  if (expectedLifecycle !== hook.lifecycle) return;
  const lifecycle = expectedLifecycle;
  if (!hook.browserSessionId || hook.bootstrapping) {
    hook.pendingDesired = payload;
    return;
  }
  const revisions = Array.isArray(payload.revisions) ? payload.revisions : [];
  const generation = Number.isInteger(payload.generation) ? payload.generation : hook.desiredGeneration;
  hook.desiredGeneration = generation;
  const epoch = ++hook.reconcileEpoch;
  hook.reconciling = true;
  hook.registryReady = false;
  const desiredNames = new Set(revisions.filter(revision => isPatchbayToolName(revision?.name)).map(revision => revision.name));
  hook.desiredRevisions = new Map(
    revisions.filter(revision => isPatchbayToolName(revision?.name)).map(revision => [revision.name, revision]),
  );

  for (const [name, record] of hook.controllers) {
    if (!desiredNames.has(name)) retireRevision(hook, name, record.revision?.generation ?? generation);
  }
  for (const [name, record] of hook.pendingRegistrations) {
    if (!desiredNames.has(name)) retireRevision(hook, name, record.revision?.generation ?? generation);
  }

  for (const revision of revisions) {
    if (!isPatchbayToolName(revision?.name) || !revision.contract_sha256) continue;
    const ready = await registerRevision(hook, revision, epoch);
    if (hook.destroyedFlag || lifecycle !== hook.lifecycle || epoch !== hook.reconcileEpoch) return;
    if (!ready) {
      hook.reconciling = false;
      throw new Error(`required Patchbay tool "${revision.name}" did not register`);
    }
  }
  if (hook.destroyedFlag || epoch !== hook.reconcileEpoch) {
    hook.reconciling = false;
    return;
  }
  const reply = await reconcileRegistry(hook, generation);
  if (hook.destroyedFlag || lifecycle !== hook.lifecycle || epoch !== hook.reconcileEpoch) return;
  if (reply?.error) throw new Error(reply.error);
  hook.reconciling = false;
  hook.registryReady = true;
  if (hook.toolchangePending) {
    hook.toolchangePending = false;
    await reportToolChange(hook);
  }
  setCapability(hook, "connected");
}

async function registerRevision(hook, revision, epoch) {
  const existing = hook.controllers.get(revision.name) ?? hook.pendingRegistrations.get(revision.name);
  if (existing?.digest === revision.contract_sha256) return existing.promise;
  if (existing) retireRevision(hook, revision.name, existing.revision?.generation ?? revision.generation);

  const tool = buildRevisionTool(hook, revision);
  const scope = createToolScope(`patchbay:${hook.roomId}:revision:${revision.name}`, [tool], {
    validate: true,
    onError: error => setCapability(hook, "error", error?.message),
  });
  const record = {
    scope,
    tool,
    revision,
    digest: revision.contract_sha256,
    retired: false,
    promise: null,
  };
  hook.pendingRegistrations.set(revision.name, record);
  record.promise = (async () => {
    const ready = await scope.ready;
    const stillDesired = hook.desiredRevisions.get(revision.name)?.contract_sha256 === revision.contract_sha256;
    if (!ready || record.retired || hook.destroyedFlag || !stillDesired) {
      if (hook.pendingRegistrations.get(revision.name) === record) {
        hook.pendingRegistrations.delete(revision.name);
      }
      if (hook.registeredDigests.get(revision.name) === revision.contract_sha256) {
        hook.registeredDigests.delete(revision.name);
      }
      return false;
    }
    hook.pendingRegistrations.delete(revision.name);
    hook.controllers.set(revision.name, record);
    hook.registeredDigests.set(revision.name, revision.contract_sha256);
    await push(hook, "webmcp_tool_registered", {
      room_id: hook.roomId,
      browser_session_id: hook.browserSessionId,
      tool_name: revision.name,
      generation: revision.generation,
      contract_sha256: revision.contract_sha256,
    }).catch(() => {});
    return true;
  })();
  return record.promise;
}

export function retireRevision(hook, name, generation = hook.desiredGeneration) {
  const record = hook.controllers.get(name) ?? hook.pendingRegistrations.get(name);
  if (!record) return;
  record.retired = true;
  record.scope?.();
  hook.controllers.delete(name);
  hook.pendingRegistrations.delete(name);
  hook.registeredDigests.delete(name);
  if (!hook.destroyedFlag) {
    void push(hook, "webmcp_tool_unregistered", {
      room_id: hook.roomId,
      browser_session_id: hook.browserSessionId,
      tool_name: name,
      generation,
      contract_sha256: record.digest,
    }).catch(() => {});
  }
}

export function retireAllRevisions(hook) {
  const names = new Set([...hook.controllers.keys(), ...hook.pendingRegistrations.keys()]);
  for (const name of names) retireRevision(hook, name);
}

function abortInvocationWork(hook, message) {
  for (const pending of hook.pendingInvocations?.values() ?? []) {
    pending.reject(new Error(message));
  }
  hook.pendingInvocations?.clear();
  for (const controller of hook.retryControllers ?? []) controller.abort();
  hook.retryControllers?.clear();
}

export async function reconcileRegistry(hook, generation = hook.desiredGeneration) {
  if (hook.destroyedFlag || !hook.modelContext) return null;
  const entries = await readOwnedTools(hook);
  const reply = await push(hook, "webmcp_registry_reconciled", {
    room_id: hook.roomId,
    browser_session_id: hook.browserSessionId,
    observed_generation: generation,
    observed_tool_names: entries.names,
    observed_contracts: entries.contracts,
  });
  return reply;
}

async function reportToolChange(hook) {
  const entries = await readOwnedTools(hook);
  if (hook.destroyedFlag) return;
  await push(hook, "webmcp_toolchange_observed", {
    room_id: hook.roomId,
    browser_session_id: hook.browserSessionId,
    observed_generation: hook.desiredGeneration,
    observed_tool_names: entries.names,
    observed_contracts: entries.contracts,
  });
}

export async function readOwnedTools(hook) {
  const names = [...hook.registeredDigests.keys()].filter(isPatchbayToolName).sort();
  const contracts = {};
  for (const name of names) contracts[name] = hook.registeredDigests.get(name);
  return {names, contracts};
}

function setCapability(hook, status, detail) {
  const messages = {
    connecting: "WebMCP connecting…",
    connected: `WebMCP connected · G${hook.desiredGeneration}`,
    unsupported: "WebMCP unavailable in this browser · room controls remain available",
    error: `WebMCP error · ${String(detail ?? "registration failed").slice(0, 160)}`,
  };
  hook.el.dataset.webmcpStatus = status;
  hook.el.dataset.webmcpSupported = status === "unsupported" ? "false" : "true";
  hook.el.textContent = messages[status] ?? "WebMCP status unknown";
  hook.el.setAttribute?.("role", "status");
  hook.el.setAttribute?.("aria-label", hook.el.textContent);
}

function push(hook, event, payload) {
  return pushWithAck(hook, event, payload);
}

function eventPrefix(hook) {
  return `patchbay:${hook.el.dataset.roomId}`;
}

function loadClientInstanceId(roomId) {
  const key = `${SESSION_KEY_PREFIX}${roomId ?? "unknown"}`;
  try {
    const existing = sessionStorage.getItem(key);
    if (existing) return existing;
    const generated = createUuid();
    sessionStorage.setItem(key, generated);
    return generated;
  } catch {
    return createUuid();
  }
}

async function digestUserAgent() {
  try {
    return await sha256Hex(typeof navigator === "undefined" ? "unknown-browser" : navigator.userAgent);
  } catch {
    return "0".repeat(64);
  }
}

function createUuid() {
  if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}
