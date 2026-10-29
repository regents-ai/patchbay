import {refusal} from "../api_error.ts";
import type {ErrorBody} from "../api_error.ts";

/**
 * What every Patchbay page tool answers, in ash-template's shape: an object the
 * browser hands the agent as it is, never JSON text inside a string.
 *
 * - `{ok: true, status, data}`: the answer; `status` is the HTTP status when the
 *   site answered, and absent when the page itself read or built it.
 * - `{ok: true, request, ...}`: a request prepared for the agent to sign.
 * - `{ok: false, status, error}`: a refusal, `error` in the site's one shape
 *   (`code`, `message`, `hint`, anything more inside it).
 * - `{ok: false, outcome: "unknown", error}`: a call whose answer was lost after
 *   it may have reached the site.
 */
export type ToolResult =
  | {ok: true; status?: number; data: unknown}
  | {ok: true; request: unknown; [field: string]: unknown}
  | {ok: false; status?: number; outcome?: "unknown"; error: ErrorBody};

/** An answer: what the site sent with its status, or what the page read itself. */
export function answered(data: unknown, status?: number): ToolResult {
  return status === undefined ? {ok: true, data} : {ok: true, status, data};
}

/** A refusal in the site's one error shape, with the site's status when it made it. */
export function refusedWith(error: ErrorBody, status?: number): ToolResult {
  return status === undefined ? {ok: false, error} : {ok: false, status, error};
}

/** A refusal the page makes itself. */
export function pageRefusal(code: string, message: string, hint: string, extra: Record<string, unknown> = {}): ToolResult {
  return {ok: false, error: refusal(code, message, hint, extra).error};
}

/** A call that may have reached the site but whose answer was lost. */
export function outcomeUnknown(code: string, message: string, hint: string): ToolResult {
  return {ok: false, outcome: "unknown", error: refusal(code, message, hint).error};
}

/**
 * `result` when its JSON fits in `limit` bytes; otherwise a refusal saying it
 * could not be returned intact. A read passes `readHint`, what to do instead:
 * it changed nothing, so its refusal says so and claims no unknown outcome.
 */
export function bounded(result: ToolResult, limit = 1100, readHint?: string): ToolResult {
  let code = "response_too_large";
  try {
    const exact = JSON.stringify(result);
    if (typeof exact !== "string") code = "invalid_result";
    else if (new TextEncoder().encode(exact).byteLength <= limit) return result;
  } catch {
    code = "invalid_result";
  }
  const error = readHint === undefined
    ? outcomeUnknown(code, "The result could not be returned intact.", "Check a write's status before retrying.")
    : pageRefusal(code, "The result could not be returned intact. This read changed nothing.", readHint);
  if (new TextEncoder().encode(JSON.stringify(error)).byteLength > limit) {
    throw new RangeError("The result limit must accommodate an error response.");
  }
  return error;
}

const MAX_SUMMARY_LENGTH = 200;

/** One sentence naming what happened, for the front of every tool result. */
export function sentence(text: unknown, limit = MAX_SUMMARY_LENGTH): string {
  const flat = String(text).replace(/\s+/g, " ").trim();
  return flat.length <= limit ? flat : `${flat.slice(0, limit - 1)}…`;
}
