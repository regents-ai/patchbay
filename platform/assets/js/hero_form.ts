import {requestAccountAction} from "./privy/account.ts"
import {keepDraft, restoreDraft, sessionStorageOrNull, type PageForm} from "./form_draft.ts"
import {mountSiteCheck} from "./site_check.ts"
import {mountToolPicker} from "./tool_picker.ts"
import {deny} from "./hooks/motion/press.ts"
import {GRIDS} from "./hooks/motion/reveals.ts"
import {lastInputByPointer, still} from "./hooks/motion/shared.ts"

const DRAFT_KEY = "pb-hero-draft"
const PICKS_KEY = "pb-hero-draft-tools"
const FIELDS = ["goal", "site_url", "details", "thread_kind", "topic_tags"]
const FIELD_NAMES = FIELDS.map(name => `ask[${name}]`)
const DETAILS = ["ask[details]", "ask[thread_kind]", "ask[topic_tags]"]
const PREVIEW_PATH = "/threads/preview"
const PICTURES = "ask[pictures][]"
const MOST_PICTURES = 3
const PICTURE_BYTES = 3 * 1024 * 1024
const PICTURE_TYPES = new Set(["image/png", "image/jpeg", "image/webp"])

const WORDS: Record<string, string> = {
  unpreviewed: "Your post could not be shown just now. Try again in a moment.",
  too_many_pictures: `Add up to ${MOST_PICTURES} pictures.`,
  picture_too_big: "Each picture can be up to 3 MB.",
  picture_kind: "Pictures can be PNG, JPEG or WebP.",
}

type HeroFormOptions = {
  document?: Document
  fetch?: typeof globalThis.fetch
  csrfToken?: string
  storage?: Storage | null
  navigate?: (url: string) => void
}

// A chosen picture, as far as the page can check it before sending.
type Picture = {size: number; type: string}

/**
 * The form at the top of the home page. What the person is trying to do,
 * the site and the tools they pick become a forum post. It shows every field
 * from the start, so nothing moves when the person starts typing, keeps what
 * they typed and the tools they picked across a sign-in, and lists the WebMCP
 * tools found at the site to pick from.
 *
 * Either post button shows the post as it will appear, in place so the
 * pictures chosen stay chosen, and its Publish button sends the form, or
 * opens sign-in first. Signed out, the form says so before anything is
 * written; the page's own Sign in keeps the draft too.
 */
export function mountHeroForm(options: HeroFormOptions = {}) {
  const doc = options.document ?? globalThis.document
  const form = doc?.getElementById?.("pb-hero-form") as PageForm | null
  if (!form) return

  const storage = options.storage === undefined ? sessionStorageOrNull() : options.storage
  restoreDraft(form, storage, DRAFT_KEY, FIELD_NAMES)
  restorePicks(form, storage)
  openFilledDetails(form)
  const picker = mountToolPicker(form)
  mountSiteCheck(form, {...options, onTools: picker?.show})
  mountKindChoice(form)

  const keep = () => {
    keepDraft(form, storage, DRAFT_KEY, FIELD_NAMES)
    keepPicks(form, storage)
  }

  // A post that was turned down comes back at the address the form
  // was sent to, which only takes a form. The address of the page the form
  // is on goes back in its place, with what was typed kept, so signing in or
  // reloading returns to this form rather than to a page that is not there.
  const view = doc.defaultView
  const home = form.dataset.pbHome!
  if (view && view.location.pathname !== home) {
    keep()
    view.history.replaceState(view.history.state, "", home)
  }

  // A post is published as it was last shown: anything changed after the
  // preview takes it away, to be shown again.
  const changed = (event: Event) => {
    if (!(event.target as Element).closest?.("#pb-hero-preview")) clearPreview(form)
  }
  form.addEventListener("input", changed)
  form.addEventListener("change", changed)

  // Signing in from the page's Sign in partway through keeps what is written.
  doc.addEventListener("click", event => {
    if ((event.target as Element).closest?.("[data-account-target='sign-in']")) keep()
  }, {capture: true})

  form.addEventListener("submit", event => {
    const submitter = event.submitter
    if (submitter?.hasAttribute("data-pb-preview")) {
      event.preventDefault()
      void preview(form, submitter, options)
    } else if (submitter?.hasAttribute("data-pb-post") && form.dataset.pbSignedIn !== "true") {
      event.preventDefault()
      keep()
      void requestAccountAction("sign-in", doc, options)
    }
  })
}

/** Why the chosen pictures cannot go with the post, or nothing when they can. */
export function picturesProblem(pictures: Picture[]): string | null {
  if (pictures.length > MOST_PICTURES) return WORDS.too_many_pictures
  if (pictures.some(picture => !PICTURE_TYPES.has(picture.type))) return WORDS.picture_kind
  if (pictures.some(picture => picture.size > PICTURE_BYTES)) return WORDS.picture_too_big
  return null
}

// The post as it will appear, asked for without sending the pictures, which
// the page shows itself from the files chosen.
async function preview(form: PageForm, button: HTMLElement, options: HeroFormOptions) {
  // How it was asked for, read before the wait: a mouse moved while the
  // preview loads does not make a keyboard request move.
  const byPointer = lastInputByPointer()
  const slot = form.querySelector<HTMLElement>("#pb-hero-preview")
  if (!slot || !form.reportValidity()) return

  const pictures = picturesOf(form)
  const problem = picturesProblem(pictures)
  if (problem) return refuse(form, button, problem)

  const body = new FormData(form)
  body.delete(PICTURES)
  try {
    const response = await (options.fetch ?? globalThis.fetch)(PREVIEW_PATH, {
      method: "POST",
      body,
      credentials: "same-origin",
      headers: {accept: "text/html"},
    })
    if (!response.ok) return refuse(form, button, WORDS.unpreviewed)
    clearPreview(form)
    // Patchbay's own page part for this form, words escaped where they were written.
    slot.innerHTML = await response.text()
  } catch {
    return refuse(form, button, WORDS.unpreviewed)
  }
  say(form, "")
  showPictures(slot, pictures)
  arrive(slot, byPointer)
  slot.querySelector("#pb-hero-post, [role=alert]")?.scrollIntoView({block: "nearest"})
}

// The preview settles in under the form when it was asked for by hand, its
// "Check before posting" box with it. A refusal of the preview never fades in:
// it is there at once and shakes, however it was asked for, unless less motion is on.
function arrive(slot: HTMLElement, byPointer: boolean) {
  const refusal = slot.querySelector<HTMLElement>(":scope > [role=alert]")
  if (refusal) deny(refusal)
  else if (byPointer && !still(slot)) GRIDS.cascade([...slot.children])
}

function showPictures(slot: HTMLElement, pictures: File[]) {
  const box = slot.querySelector<HTMLElement>("[data-pb-preview-pictures]")
  if (!box) return
  box.replaceChildren(
    ...pictures.map((picture, index) => {
      const image = slot.ownerDocument.createElement("img")
      image.src = URL.createObjectURL(picture)
      image.alt = `Picture ${index + 1} you added`
      return image
    }),
  )
}

function clearPreview(form: PageForm) {
  const slot = form.querySelector<HTMLElement>("#pb-hero-preview")
  if (!slot || slot.childElementCount === 0) return
  for (const image of slot.querySelectorAll<HTMLImageElement>("[data-pb-preview-pictures] img")) {
    URL.revokeObjectURL(image.src)
  }
  slot.replaceChildren()
}

function picturesOf(form: PageForm) {
  const field = form.elements[PICTURES] as HTMLInputElement | undefined
  return Array.from(field?.files ?? [])
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

// Details put back after a sign-in are shown, not folded away.
function openFilledDetails(form: PageForm) {
  const details = form.querySelector<HTMLDetailsElement>("#pb-hero-details")
  if (details && DETAILS.some(name => (form.elements[name]?.value ?? "") !== "")) details.open = true
}

function picksOf(form: PageForm) {
  return Array.from(form.querySelectorAll<HTMLInputElement>("input[name='ask[tools][]']:checked"), input => input.value)
}

// The picked tools ride across a sign-in the way the texts do, and the
// list takes them back once it is shown again.
function keepPicks(form: PageForm, storage: Storage | null) {
  try {
    storage?.setItem(PICKS_KEY, picksOf(form).join("\n"))
  } catch {
    // A page that cannot keep the picks still signs in.
  }
}

function restorePicks(form: PageForm, storage: Storage | null) {
  const box = form.querySelector<HTMLElement>("#pb-fix-tools")
  try {
    const kept = storage?.getItem(PICKS_KEY)
    storage?.removeItem(PICKS_KEY)
    if (box && kept) box.dataset.pbPicked = kept
  } catch {
    // Nothing kept, nothing to put back.
  }
}

function say(form: PageForm, words: string) {
  const status = form.querySelector("#pb-fix-status")
  if (status) status.textContent = words
}

// The reason is said under the buttons, and the button pressed shakes its head.
function refuse(form: PageForm, button: HTMLElement, words: string) {
  say(form, words)
  deny(button)
}
