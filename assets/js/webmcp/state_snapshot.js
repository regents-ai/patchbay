const encoder = new TextEncoder();

/**
 * Capture the values the person can actually see in the room. Textarea
 * `value` is intentional: LiveView's text node can be stale after local edits.
 */
export async function captureRoomState(root = document) {
  const stateElement = find(root, "#patchbay-room-state");
  const sourceElement = find(root, "#patchbay-source-editor");
  const candidateElement = find(root, "#patchbay-candidate-editor");
  const source = readValue(sourceElement);
  const candidate = readValue(candidateElement);
  const candidatePresent = candidate.trim().length > 0;

  const [sourceSha, candidateSha] = await Promise.all([
    sha256Hex(source),
    candidatePresent ? sha256Hex(candidate) : Promise.resolve(null),
  ]);

  return {
    room_id: stateElement?.dataset?.roomId ?? null,
    ui_revision: numberValue(stateElement?.dataset?.uiRevision, 0),
    source: {
      present: Boolean(sourceElement),
      sha256: sourceSha,
      byte_length: byteLength(source),
    },
    candidate: {
      present: candidatePresent,
      sha256: candidatePresent ? candidateSha : null,
      byte_length: candidatePresent ? byteLength(candidate) : 0,
    },
  };
}

export function readRoomMetadata(root = document) {
  const stateElement = find(root, "#patchbay-room-state");
  const roomElement = find(root, "#patchbay-room");
  return {
    roomId: stateElement?.dataset?.roomId ?? roomElement?.dataset?.roomId ?? null,
    roomSlug: roomElement?.dataset?.roomSlug ?? null,
    status: stateElement?.dataset?.status ?? null,
    generation: numberValue(
      stateElement?.dataset?.desiredGeneration ?? roomElement?.dataset?.generation,
      null,
    ),
    observedGeneration: numberValue(stateElement?.dataset?.observedGeneration, null),
    candidateSha256: stateElement?.dataset?.candidateSha256 || null,
    verificationPassed: stateElement?.dataset?.verificationPassed === "true",
    failureCode: stateElement?.dataset?.failureCode || null,
    repairStatus: stateElement?.dataset?.repairStatus || null,
    repairApproved: stateElement?.dataset?.repairApproved === "true",
  };
}

/** The text the person can actually see in one of the room's editors. */
export function readVisibleText(root = document, selector) {
  return readValue(find(root, selector));
}

export async function sha256Hex(value) {
  const subtle = globalThis.crypto?.subtle;
  if (!subtle?.digest) throw new Error("Web Crypto SHA-256 is unavailable");

  const digest = await subtle.digest("SHA-256", encoder.encode(String(value)));
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
}

export function byteLength(value) {
  return encoder.encode(String(value)).byteLength;
}

function find(root, selector) {
  if (root?.querySelector) {
    const result = root.querySelector(selector);
    if (result) return result;
  }

  if (typeof document !== "undefined" && document !== root) {
    return document.querySelector?.(selector) ?? null;
  }

  return null;
}

function readValue(element) {
  if (!element) return "";
  return typeof element.value === "string" ? element.value : element.textContent ?? "";
}

function numberValue(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}
