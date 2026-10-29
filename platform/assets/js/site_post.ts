/**
 * A site page's post window: the home page's form in a dialog. The "Post
 * about" button and an empty list's "Ask a question" open it with the question
 * box focused, and closing it gives focus back to what opened it. It opens by
 * itself when the page comes back from a post with a problem to fix or a post
 * to check, or from a sign-in with a draft to finish. A press on the dimmed page around it closes it, as Escape does;
 * a press inside it, padding included, never does.
 */
export function mountSitePost(doc: Document = globalThis.document) {
  const dialog = doc?.getElementById?.("pb-site-post") as HTMLDialogElement | null
  if (!dialog) return
  let opener: HTMLElement | null = null

  const open = (from: HTMLElement | null) => {
    opener = from
    if (!dialog.open) dialog.showModal()
    // A phone's full-height window must not scroll its close button away.
    dialog.querySelector<HTMLInputElement>("#pb-fix-goal")?.focus({preventScroll: true})
  }

  doc.addEventListener("click", event => {
    const link = (event.target as Element | null)?.closest?.<HTMLElement>("a[href='#pb-site-post']")
    if (!link) return
    event.preventDefault()
    open(link)
  })

  dialog.addEventListener("click", event => {
    if (event.target !== dialog) return
    const box = dialog.getBoundingClientRect()
    const outside = event.clientX < box.left || event.clientX > box.right ||
      event.clientY < box.top || event.clientY > box.bottom
    if (outside) dialog.close()
  })

  dialog.addEventListener("close", () => {
    opener?.focus()
    opener = null
  })

  // Also when a draft was put back after a sign-in (hero_form.ts marks the form).
  const restored = dialog.querySelector<HTMLElement>("#pb-hero-form")?.dataset.pbRestored === "true"
  if (dialog.dataset.pbOpenOnLoad === "true" || restored) {
    open(doc.querySelector<HTMLElement>(".pb-site-post-button"))
  }
}
