import {getModelContext} from "./webmcpify.js";
import {registerForumTools} from "./forum_tools.js";

/** A document owns one forum scope, including when restored from the back/forward cache. */
export function mountForumTools(win, options = {}) {
  let scope;
  const show = () => {
    if (!scope) scope = registerForumTools(getModelContext(), options);
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
