/**
 * What a person typed into a form, kept in this browser tab while a sign-in
 * reloads the page, and put back once when the page comes back. A field the
 * page already filled keeps what the page gave it; a choice list takes the
 * kept choice.
 */

// A text box or a choice list, which is all a draft reads and fills.
type DraftField = {value: string; readonly tagName: string}

type DraftForm = {elements: Record<string, DraftField | undefined>}

export type PageForm = HTMLFormElement & {
  elements: Record<string, HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement | undefined>
}

type DraftStorage = Pick<Storage, "getItem" | "setItem" | "removeItem">

/**
 * @param names the fields' full names, like "ask[goal]"
 */
export function keepDraft(form: DraftForm, storage: DraftStorage | null, key: string, names: string[]) {
  const fields = Object.fromEntries(names.map(name => [name, form.elements[name]?.value ?? ""]))
  try {
    storage?.setItem(key, JSON.stringify(fields))
  } catch {
    // A page that cannot keep the draft still signs in.
  }
}

export function restoreDraft(form: DraftForm, storage: DraftStorage | null, key: string, names: string[]) {
  let kept: string | null | undefined
  try {
    kept = storage?.getItem(key)
    storage?.removeItem(key)
  } catch {
    return
  }
  if (!kept) return
  let draft: Record<string, unknown>
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

export function sessionStorageOrNull() {
  try {
    return globalThis.sessionStorage ?? null
  } catch {
    return null
  }
}
