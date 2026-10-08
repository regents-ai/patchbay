type WalletBenchOptions = {document?: Document; fetch?: typeof globalThis.fetch}

type PairState = {wbPair: string; title: string}

/**
 * The Agent Wallet Bench grid. Opening a square shows that pair's runs in a
 * full-screen dialog over the grid, and the address becomes the pair's own
 * page, so Back closes it and a reload or a shared link opens the page itself.
 * Each square stays an ordinary link: a new tab, or a page without scripts,
 * opens the pair's page.
 */
export function mountWalletBench(options: WalletBenchOptions = {}) {
  const doc = options.document ?? globalThis.document
  const bench = doc?.getElementById?.("patchbay-wallet-bench")
  const dialog = doc?.getElementById?.("pb-wb-dialog") as HTMLDialogElement | null
  if (!bench || !dialog) return

  const fetcher = options.fetch ?? globalThis.fetch
  const bar = dialog.querySelector<HTMLElement>(".pb-wb-dialog-bar")!
  const title = dialog.querySelector<HTMLElement>("#pb-wb-dialog-title")!
  const body = dialog.querySelector<HTMLElement>("[data-wb-body]")!
  const error = dialog.querySelector<HTMLElement>("[data-wb-error]")!
  const page = dialog.querySelector<HTMLAnchorElement>("[data-wb-page]")!
  let inFlight: AbortController | null = null

  const show = async ({wbPair, title: name}: PairState) => {
    inFlight?.abort()
    inFlight = new AbortController()
    title.textContent = name
    body.replaceChildren()
    error.hidden = true
    page.href = wbPair
    if (!dialog.open) dialog.showModal()
    dialog.scrollTop = 0

    try {
      const response = await fetcher(wbPair, {
        headers: {accept: "text/html"},
        credentials: "same-origin",
        signal: inFlight.signal,
      })
      const found = response.ok
        ? new DOMParser().parseFromString(await response.text(), "text/html").getElementById("pb-wb-pair")
        : null
      if (!found) {
        error.hidden = false
        return
      }
      body.replaceChildren(doc.importNode(found, true))
      // The square's own grid starts just under the dialog's bar.
      const grid = new URL(wbPair, doc.baseURI).hash.slice(1)
      const section = grid ? body.querySelector(`#${CSS.escape(grid)}`) : null
      if (section) dialog.scrollTop += section.getBoundingClientRect().top - bar.getBoundingClientRect().bottom
    } catch (reason) {
      if (!(reason instanceof DOMException && reason.name === "AbortError")) error.hidden = false
    }
  }

  bench.addEventListener("click", event => {
    const square = (event.target as Element | null)?.closest?.<HTMLAnchorElement>("a.pb-wb-square")
    if (!square || event.defaultPrevented || event.button !== 0) return
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    event.preventDefault()

    const state: PairState = {wbPair: square.getAttribute("href")!, title: square.dataset.wbPair!}
    globalThis.history.pushState(state, "", state.wbPair)
    show(state)
  })

  // Closing the dialog, by its button or Escape, takes the address back to the grid.
  dialog.addEventListener("close", () => {
    inFlight?.abort()
    if ((globalThis.history.state as PairState | null)?.wbPair) globalThis.history.back()
  })

  // Back and Forward close and reopen it.
  globalThis.addEventListener("popstate", event => {
    const state = event.state as PairState | null
    if (state?.wbPair) show(state)
    else if (dialog.open) dialog.close()
  })
}
