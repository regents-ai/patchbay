import {keepDraft, restoreDraft, sessionStorageOrNull} from "./form_draft.js"
import {requestAccountAction} from "./privy/account.js"

const DRAFT_KEY = "pb-ask-draft"
const FIELDS = ["site", "thread_kind", "title", "body_markdown", "subject_tool_name", "topic_tags"].map(
  name => `thread[${name}]`,
)

/**
 * The ask form. Signed out, what is typed is kept in this tab as it is
 * typed, and pressing Post question opens sign-in instead of posting; the
 * page the sign-in reloads, from that button or the one at the top of the
 * page, puts it back, ready to post.
 *
 * @param {{document?: Document, storage?: Storage | null}} [options]
 */
export function mountAskForm(options = {}) {
  const doc = options.document ?? globalThis.document
  const form = doc?.getElementById?.("pb-ask-form")
  if (!form) return

  const storage = options.storage === undefined ? sessionStorageOrNull() : options.storage
  restoreDraft(form, storage, DRAFT_KEY, FIELDS)

  if (form.dataset.pbSignedIn === "true") return

  const keep = () => keepDraft(form, storage, DRAFT_KEY, FIELDS)
  form.addEventListener("input", keep)
  form.addEventListener("change", keep)
  form.addEventListener("submit", event => {
    event.preventDefault()
    keep()
    void requestAccountAction("sign-in", doc, options)
  })
}
