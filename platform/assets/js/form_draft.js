/**
 * What a person typed into a form, kept in this browser tab while a sign-in
 * reloads the page, and put back once when the page comes back. A field the
 * page already filled keeps what the page gave it; a choice list takes the
 * kept choice.
 */

/**
 * @param {HTMLFormElement} form
 * @param {Storage | null} storage
 * @param {string} key
 * @param {string[]} names the fields' full names, like "fix[goal]"
 */
export function keepDraft(form, storage, key, names) {
  const fields = Object.fromEntries(names.map(name => [name, form.elements[name]?.value ?? ""]))
  try {
    storage?.setItem(key, JSON.stringify(fields))
  } catch {
    // A page that cannot keep the draft still signs in.
  }
}

/**
 * @param {HTMLFormElement} form
 * @param {Storage | null} storage
 * @param {string} key
 * @param {string[]} names
 */
export function restoreDraft(form, storage, key, names) {
  let kept
  try {
    kept = storage?.getItem(key)
    storage?.removeItem(key)
  } catch {
    return
  }
  if (!kept) return
  let draft
  try {
    draft = JSON.parse(kept)
  } catch {
    return
  }
  for (const name of names) {
    const field = form.elements[name]
    const value = draft[name]
    if (!field || typeof value !== "string" || value === "") continue
    if (field.tagName === "SELECT" || field.value === "") field.value = value
  }
}

/** This tab's session storage, or null where the browser will not give it. */
export function sessionStorageOrNull() {
  try {
    return globalThis.sessionStorage ?? null
  } catch {
    return null
  }
}
