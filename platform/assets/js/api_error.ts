/**
 * The one shape every Patchbay refusal takes, the same one the server's
 * `PatchbayWeb.ApiError` writes: a stable `code` to branch on, the words, and
 * the `hint` that says what to do about it. Whatever else a refusal carries
 * sits inside `error` beside them; nothing stands beside `error` itself.
 */
export type ErrorBody = {code: string; message: string; hint: string; [field: string]: unknown};

export type Refusal = {error: ErrorBody};

/** A refusal this page makes itself, in the shape the server's take. */
export function refusal(code: string, message: string, hint: string, extra: Record<string, unknown> = {}): Refusal {
  return {error: {...extra, code, message, hint}};
}

export function isErrorBody(value: unknown): value is ErrorBody {
  if (typeof value !== "object" || value === null) return false;
  const {code, message, hint} = value as {code?: unknown; message?: unknown; hint?: unknown};
  return typeof code === "string" && typeof message === "string" && typeof hint === "string";
}

/** The refusal a JSON answer carries, or null when the answer is not one. */
export function errorIn(body: unknown): ErrorBody | null {
  const error = (body as {error?: unknown} | null | undefined)?.error;
  return isErrorBody(error) ? error : null;
}
