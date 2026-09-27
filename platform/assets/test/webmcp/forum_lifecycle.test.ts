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
  }};
  globalThis.document = {modelContext} as unknown as Document;
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
    await Promise.resolve();
    await Promise.resolve();
    assert.equal(tools.size, FORUM_TOOL_NAMES.length);
    assert.deepEqual(errors, []);
    stop();
    win.dispatchEvent(new Event("pageshow"));
    assert.equal(tools.size, 0);
    assert.equal(calls, FORUM_TOOL_NAMES.length * 2);
  } finally {
    stop();
    globalThis.document = previous;
  }
});
