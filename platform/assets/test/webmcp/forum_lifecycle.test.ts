import assert from "node:assert/strict";
import test from "node:test";
import {mountForumTools} from "../../js/webmcp/forum_lifecycle.ts";
import {FORUM_TOOL_NAMES} from "../../js/webmcp/forum_tools.ts";

test("page restoration registers once and an old failure cannot dispose the new scope", async () => {
  const previous = globalThis.document;
  const tools = new Map<string, {name: string}>();
  let calls = 0;
  let rejectOld!: (error: Error) => void;
  const modelContext = {registerTool(tool: {name: string}, {signal}: {signal: AbortSignal}) {
    calls++;
    tools.set(tool.name, tool);
    signal.addEventListener("abort", () => {
      if (tools.get(tool.name) === tool) tools.delete(tool.name);
    }, {once: true});
    if (calls === 1) return new Promise((_resolve, reject) => { rejectOld = reject; });
    return Promise.resolve();
  }, getTools: async () => [...tools.values()]};
  const documentElement = {dataset: {} as DOMStringMap};
  globalThis.document = {modelContext, documentElement} as unknown as Document;
  const win = new EventTarget();
  const errors: unknown[] = [];
  const stop = mountForumTools(win, {onError: error => errors.push(error)});
  try {
    win.dispatchEvent(new Event("pageshow"));
    assert.equal(calls, FORUM_TOOL_NAMES.length);
    win.dispatchEvent(new Event("pagehide"));
    assert.equal(tools.size, 0);
    win.dispatchEvent(new Event("pageshow"));
    win.dispatchEvent(new Event("pageshow"));
    assert.equal(calls, FORUM_TOOL_NAMES.length * 2);
    rejectOld(new Error("old registration failed"));
    await new Promise(settled => setTimeout(settled, 0));
    assert.equal(tools.size, FORUM_TOOL_NAMES.length);
    assert.deepEqual(errors, []);
    // The old scope's failure never writes over the current scope's status.
    assert.equal(documentElement.dataset.webmcpStatus, "connected");
    stop();
    win.dispatchEvent(new Event("pageshow"));
    assert.equal(tools.size, 0);
    assert.equal(calls, FORUM_TOOL_NAMES.length * 2);
  } finally {
    stop();
    globalThis.document = previous;
  }
});

test("the page's status says whether the browser holds every forum tool", async () => {
  const previous = globalThis.document;
  const settle = () => new Promise(settled => setTimeout(settled, 0));
  const page = (modelContext: unknown) => {
    const documentElement = {dataset: {} as DOMStringMap};
    globalThis.document = {modelContext, documentElement} as unknown as Document;
    return documentElement.dataset;
  };
  try {
    const none = page(undefined);
    mountForumTools(new EventTarget())();
    assert.equal(none.webmcpStatus, "unsupported");

    // The browser accepted every tool but lists one fewer than the page offered.
    const short = page({registerTool: () => Promise.resolve(), getTools: async () => FORUM_TOOL_NAMES.slice(1).map(name => ({name}))});
    const stopShort = mountForumTools(new EventTarget());
    await settle();
    assert.equal(short.webmcpStatus, "error");
    stopShort();

    const refused = page({registerTool: () => Promise.reject(new Error("tools permission denied")), getTools: async () => []});
    const stopRefused = mountForumTools(new EventTarget(), {onError: () => {}});
    await settle();
    assert.equal(refused.webmcpStatus, "error");
    stopRefused();
  } finally {
    globalThis.document = previous;
  }
});
