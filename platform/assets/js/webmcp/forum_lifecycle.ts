import {getModelContext} from "./webmcpify.ts";
import {offeredToolNames, registerForumTools} from "./forum_tools.ts";
import type {ForumToolOptions} from "./forum_tools.ts";

/**
 * A document owns one forum scope, including when restored from the back/forward
 * cache. Its `<html data-webmcp-status>` says what the browser holds: `connected`
 * once getTools() lists every forum tool this address offers, `error` when
 * registration failed or a tool is missing, `unsupported` with no WebMCP. Only
 * the latest scope writes it.
 */
export function mountForumTools(win: EventTarget, options: ForumToolOptions = {}) {
  let scope: ReturnType<typeof registerForumTools> | undefined;
  const status = (state: string) => { globalThis.document.documentElement.dataset.webmcpStatus = state; };
  const show = () => {
    if (scope) return;
    const modelContext = getModelContext();
    const current = registerForumTools(modelContext, options);
    scope = current;
    if (!modelContext) return status("unsupported");
    current.ready
      .then(async registered => {
        if (!registered) return false;
        const names = new Set((await modelContext.getTools!()).map(tool => tool.name));
        return offeredToolNames(options.leftOut).every(name => names.has(name));
      })
      .then(
        held => { if (scope === current) status(held ? "connected" : "error"); },
        () => { if (scope === current) status("error"); },
      );
  };
  const hide = () => {
    scope?.();
    scope = undefined;
  };
  win.addEventListener("pagehide", hide);
  win.addEventListener("pageshow", show);
  show();
  return () => {
    win.removeEventListener("pagehide", hide);
    win.removeEventListener("pageshow", show);
    hide();
  };
}
