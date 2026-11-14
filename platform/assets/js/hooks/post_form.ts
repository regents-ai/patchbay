import {requestAccountAction} from "../privy/account.ts"
import {keepDraft, restoreDraft, sessionStorageOrNull, type PageForm} from "../form_draft.ts"
import {returnedFromOAuth} from "../privy/sign_in.ts"
import {mountSiteCheck} from "../site_check.ts"
import {mountToolPicker} from "../tool_picker.ts"
import {deny} from "./motion/press.ts"
import {GRIDS} from "./motion/reveals.ts"
import {lastInputByPointer, still} from "./motion/shared.ts"
import type {Hook} from "../hook_composition.ts"

const FIELD_NAMES = ["goal", "site_url", "details", "thread_kind", "topic_tags"].map(name => `ask[${name}]`)
const DETAILS = ["ask[details]", "ask[thread_kind]", "ask[topic_tags]"]

type Reach = {to: string; line: string}

type PostFormHook = {
  el: PageForm
  handleEvent(event: "pb:reach", callback: (reach: Reach) => void): void
  handleEvent(event: "pb:previewed", callback: () => void): void
  stop?: () => void
}

/**
 * What the post form does in the browser (`PatchbayWeb.PostFormLive`): it
 * keeps what was typed and the tools picked across a sign-in, lists the
 * WebMCP tools found at the site to pick from, and lets the picked type of
 * post be unpicked. Publish post signed out opens sign-in first, keeping the
 * draft; the page's own Sign in keeps it too.
 *
 * A press refused over a field opens that field's section, puts the cursor
 * in it and shakes the line that says what to fix. A preview asked for by
 * hand settles in under the form.
 */
export const PostForm: Hook = {
  mounted(this: PostFormHook) {
    const form = this.el
    const doc = form.ownerDocument
    const storage = sessionStorageOrNull()
    // Each page's form keeps its own draft, so one typed on /hermes stays there.
    const home = form.dataset.pbHome!
    const draftKey = `pb-hero-draft:${home}`
    const picksKey = `pb-hero-draft-tools:${home}`

    const restored = restoreDraft(form, storage, draftKey, FIELD_NAMES)
    restorePicks(form, storage, picksKey)
    const picker = mountToolPicker(form)
    mountSiteCheck(form, {onTools: picker?.show})
    mountKindChoice(form)
    if (restored) showRestored(form)

    const keep = () => {
      keepDraft(form, storage, draftKey, FIELD_NAMES)
      keepPicks(form, storage, picksKey)
    }

    // Privy brings a Google or other redirect sign-in back to this page, which
    // finishes the sign-in and reloads (privy/account.ts): what was put back is
    // kept once more for the page after it.
    if (returnedFromOAuth(doc.defaultView?.location.search ?? "")) keep()

    // Signing in partway through keeps what is written. The page's Sign in is
    // the header's, or the post window's own while the window covers the header;
    // the window closes first, so Privy's sign-in opens above the page.
    const signingIn = (event: Event) => {
      if (!(event.target as Element).closest?.("[data-account-target='sign-in']")) return
      keep()
      form.closest("dialog")?.close()
    }
    doc.addEventListener("click", signingIn, {capture: true})

    // How the press was made, read before the answer: a mouse moved while the
    // preview loads does not make a keyboard press move.
    let byPointer = false
    form.addEventListener("submit", event => {
      byPointer = lastInputByPointer()
      if (!event.submitter?.hasAttribute("data-pb-post") || form.dataset.pbSignedIn === "true") return
      // Signed out, Publish post opens sign-in instead of reaching the page.
      event.preventDefault()
      event.stopPropagation()
      keep()
      form.closest("dialog")?.close()
      void requestAccountAction("sign-in", doc, {csrfToken: csrfToken(doc)})
    })

    this.handleEvent("pb:reach", ({to, line}) => reach(form, to, line))
    this.handleEvent("pb:previewed", () => arrive(form, byPointer))
    this.stop = () => doc.removeEventListener("click", signingIn, {capture: true})
  },

  destroyed(this: PostFormHook) {
    this.stop?.()
  },
}

// A draft put back shows itself: home's Ask a question opens, a site page's
// post window opens (site_post.ts), and so do the details holding any of it.
// The form's part of the page is told what was put back.
function showRestored(form: PageForm) {
  const ask = form.closest<HTMLDetailsElement>("details#pb-ask")
  if (ask) ask.open = true
  form.dispatchEvent(new CustomEvent("pb:restored", {bubbles: true}))
  const details = form.querySelector<HTMLDetailsElement>("#pb-hero-details")
  if (details && DETAILS.some(name => (form.elements[name]?.value ?? "") !== "")) details.open = true
  form.elements["ask[goal]"]?.dispatchEvent(new Event("input", {bubbles: true}))
}

// The field to fix under the cursor, its section opened first, with the line
// that says what to fix in view, shaking as a refusal does. LiveView gives the
// focus back to the pressed button once it has handled the answer, so the
// field takes it on the next frame, after that.
function reach(form: PageForm, to: string, line: string) {
  const field = form.querySelector<HTMLElement>(`#${to}`)
  const said = form.querySelector<HTMLElement>(`#${line}`)
  if (!field || !said) return
  const section = field.closest("details")
  if (section) section.open = true
  requestAnimationFrame(() => {
    field.focus()
    said.scrollIntoView({block: "nearest"})
    deny(said)
  })
}

// The preview settles in under the form when it was asked for by hand.
function arrive(form: PageForm, byPointer: boolean) {
  const slot = form.querySelector<HTMLElement>("#pb-hero-preview")
  const post = slot?.querySelector<HTMLElement>("#pb-hero-post")
  if (!slot || !post) return
  if (byPointer && !still(slot)) GRIDS.cascade([...slot.children])
  post.scrollIntoView({block: "nearest"})
}

// The type of post is one pick at a time, and pressing the picked one again
// unpicks it, so Patchbay chooses, as when none is picked.
function mountKindChoice(form: PageForm) {
  const selector = "input[name='ask[thread_kind]']"
  let picked = form.querySelector<HTMLInputElement>(`${selector}:checked`)
  const unpick = (input: HTMLInputElement) => {
    input.checked = false
    picked = null
    input.dispatchEvent(new Event("change", {bubbles: true}))
  }
  for (const input of form.querySelectorAll<HTMLInputElement>(selector)) {
    input.addEventListener("click", () => {
      if (input === picked) unpick(input)
      else picked = input
    })
    // Space on the picked one sends no click, so it is heard here.
    input.addEventListener("keydown", event => {
      if (event.key !== " " || input !== picked) return
      event.preventDefault()
      unpick(input)
    })
  }
}

function picksOf(form: PageForm) {
  return Array.from(form.querySelectorAll<HTMLInputElement>("input[name='ask[tools][]']:checked"), input => input.value)
}

// The picked tools ride across a sign-in the way the texts do, and the
// list takes them back once it is shown again.
function keepPicks(form: PageForm, storage: Storage | null, key: string) {
  try {
    storage?.setItem(key, picksOf(form).join("\n"))
  } catch {
    // A page that cannot keep the picks still signs in.
  }
}

function restorePicks(form: PageForm, storage: Storage | null, key: string) {
  const box = form.querySelector<HTMLElement>("#pb-fix-tools")
  try {
    const kept = storage?.getItem(key)
    storage?.removeItem(key)
    if (box && kept) box.dataset.pbPicked = kept
  } catch {
    // Nothing kept, nothing to put back.
  }
}

function csrfToken(doc: Document) {
  return doc.querySelector("meta[name='csrf-token']")?.getAttribute("content") ?? undefined
}
