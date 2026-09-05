/**
 * Who the page is being read by, as the server named them.
 *
 * The signed session decides this and the page publishes it; nothing the
 * browser holds can change it. A page nobody is signed in on carries no such
 * name at all, which is what the tools that need one read as anonymous.
 *
 * @param {Document} [doc]
 * @returns {string | null}
 */
export function signedInProfileId(doc = globalThis.document) {
  const content = doc?.querySelector?.('meta[name="pb-profile"]')?.getAttribute("content")
  const trimmed = typeof content === "string" ? content.trim() : ""
  return trimmed === "" ? null : trimmed
}
