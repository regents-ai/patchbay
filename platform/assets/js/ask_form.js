import {keepDraft, restoreDraft, sessionStorageOrNull} from "./form_draft.js"
import {requestAccountAction} from "./privy/account.js"

const DRAFT_KEY = "pb-ask-draft"
const FIELDS = ["site", "thread_kind", "title", "body_markdown", "subject_tool_name", "topic_tags"].map(
  name => `thread[${name}]`,
)
const RELATED_AFTER_MS = 500
const RELATED_MIN_LENGTH = 4
const RELATED_SHOWN = 3

/**
 * The ask form. While the person types what they were trying to do, questions
 * already asked about it are listed under the line, so an existing answer is
 * found before a new question is written.
 *
 * Signed out, what is typed is kept in this tab, and pressing Post question
 * opens sign-in instead of posting; the page the sign-in reloads, from that
 * button or the one at the top of the page, puts it back. A preview is shown
 * by posting the form, so a signed-out preview page names itself /ask again:
 * a reload then reads the form afresh instead of sending it a second time.
 *
 * @param {{document?: Document, storage?: Storage | null, fetch?: typeof fetch}} [options]
 */
export function mountAskForm(options = {}) {
  const doc = options.document ?? globalThis.document
  const form = doc?.getElementById?.("pb-ask-form")
  if (!form) return

  showRelated(form, doc, options.fetch ?? globalThis.fetch)

  const storage = options.storage === undefined ? sessionStorageOrNull() : options.storage
  restoreDraft(form, storage, DRAFT_KEY, FIELDS)

  if (form.dataset.pbSignedIn === "true") return

  const keep = () => keepDraft(form, storage, DRAFT_KEY, FIELDS)
  form.addEventListener("input", keep)
  form.addEventListener("change", keep)

  if (doc.getElementById("pb-ask-preview")) {
    keep()
    globalThis.history?.replaceState?.(null, "", "/ask")
  }

  form.addEventListener("submit", event => {
    if (!event.submitter?.hasAttribute("data-pb-post")) return
    event.preventDefault()
    keep()
    void requestAccountAction("sign-in", doc, options)
  })
}

function showRelated(form, doc, fetchImpl) {
  const title = form.elements["thread[title]"]
  const box = doc.getElementById("pb-ask-related")
  if (!title || !box || typeof fetchImpl !== "function") return

  let timer = null
  let inFlight = null

  const look = async () => {
    const words = title.value.trim()
    inFlight?.abort()
    if (words.length < RELATED_MIN_LENGTH) return render(box, [])

    inFlight = new AbortController()
    try {
      const response = await fetchImpl(`/forum/search?q=${encodeURIComponent(words)}`, {
        headers: {accept: "application/json"},
        credentials: "same-origin",
        signal: inFlight.signal,
      })
      const body = response.ok ? await response.json() : null
      render(box, Array.isArray(body?.results) ? body.results.slice(0, RELATED_SHOWN) : [])
    } catch {
      // Suggestions are a help, not a step: without them the form still posts.
    }
  }

  title.addEventListener("input", () => {
    clearTimeout(timer)
    timer = setTimeout(look, RELATED_AFTER_MS)
  })
  if (title.value.trim() !== "") void look()
}

function render(box, results) {
  const list = box.querySelector("ul")
  list.replaceChildren(
    ...results.map(result => {
      const item = box.ownerDocument.createElement("li")
      const link = box.ownerDocument.createElement("a")
      link.href = `/posts/${encodeURIComponent(result.id)}`
      link.textContent = result.title ?? "Untitled discussion"
      const site = box.ownerDocument.createElement("span")
      site.textContent = ` · ${result.site}`
      item.append(link, site)
      return item
    }),
  )
  box.hidden = results.length === 0
}
