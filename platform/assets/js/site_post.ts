/**
 * A site page's post window: the home page's form in a dialog. Every link to
 * it ("Post about", the header's link, an empty list's "Ask a question")
 * opens it with the question box focused. It opens by itself when the page
 * comes back from a post with a problem to fix or a post to check. A press on
 * the dimmed page around it closes it, as Escape does.
 */
export function mountSitePost(doc: Document = globalThis.document) {
  const dialog = doc?.getElementById?.("pb-site-post") as HTMLDialogElement | null
  if (!dialog) return

  const open = () => {
    if (!dialog.open) dialog.showModal()
    dialog.querySelector<HTMLInputElement>("#pb-fix-goal")?.focus()
  }

  doc.addEventListener("click", event => {
    const link = (event.target as Element | null)?.closest?.("a[href='#pb-site-post']")
    if (!link) return
    event.preventDefault()
    open()
  })

  dialog.addEventListener("click", event => {
    if (event.target === dialog) dialog.close()
  })

  if (dialog.dataset.pbOpenOnLoad === "true") open()
}
