type WalletBenchOptions = {document?: Document; fetch?: typeof globalThis.fetch}
type PairState = {wbPair: string; title: string}

/** The board, with a progressively enhanced, full-screen result page. */
export function mountWalletBench(options: WalletBenchOptions = {}) {
  const doc = options.document ?? globalThis.document
  const bench = doc?.getElementById?.("patchbay-wallet-bench")
  if (!bench || bench.dataset.wbMounted) return
  bench.dataset.wbMounted = "true"
  keepFilterAddressShort(doc)
  mountStatus(bench)
  const dialog = doc.getElementById("pb-wb-dialog") as HTMLDialogElement | null
  if (!dialog || typeof dialog.showModal !== "function") return
  const view = doc.defaultView!
  const fetcher = options.fetch ?? globalThis.fetch
  const title = dialog.querySelector<HTMLElement>("#pb-wb-dialog-title")!
  const body = dialog.querySelector<HTMLElement>("[data-wb-body]")!
  const error = dialog.querySelector<HTMLElement>("[data-wb-error]")!
  const loading = dialog.querySelector<HTMLElement>("[data-wb-loading]")!
  const page = dialog.querySelector<HTMLAnchorElement>("[data-wb-page]")!
  // The shared window frame scrolls its inner area, under the bar.
  const scroller = dialog.querySelector<HTMLElement>(".rg-dialog__body")!
  let inFlight: AbortController | null = null
  let returnFocus: HTMLElement | null = null
  let closingFromHistory = false

  const pairURL = (value: string) => {
    const url = new URL(value, doc.baseURI)
    return url.origin === view.location.origin && /^\/wallet-bench\/[^/]+\/[^/]+$/.test(url.pathname)
      ? url : null
  }
  const show = async ({wbPair, title: name}: PairState) => {
    const url = pairURL(wbPair)
    if (!url) return
    inFlight?.abort()
    const request = new AbortController()
    inFlight = request
    title.textContent = name
    body.replaceChildren()
    body.setAttribute("aria-busy", "true")
    error.hidden = true
    loading.hidden = false
    page.href = url.href
    if (!dialog.open) dialog.showModal()
    scroller.scrollTop = 0
    try {
      const response = await fetcher(url.href, {
        headers: {accept: "text/html"}, credentials: "same-origin", signal: request.signal,
      })
      const html = response.ok ? await response.text() : ""
      // Aborting transport is not enough: an already resolved body can arrive late.
      if (inFlight !== request || request.signal.aborted || !dialog.open) return
      const found = new DOMParser().parseFromString(html, "text/html").getElementById("pb-wb-pair")
      if (!found) { error.hidden = false; return }
      body.replaceChildren(doc.importNode(found, true))
      const focusId = url.hash && url.hash !== "#recorded-run"
        ? url.hash.slice(1) : found.dataset.wbFocus || url.hash.slice(1)
      const section = focusId ? body.querySelector<HTMLElement>(`#${CSS.escape(focusId)}`) : null
      section?.scrollIntoView({block: "start", behavior: "instant"})
    } catch {
      if (inFlight === request && !request.signal.aborted && dialog.open) error.hidden = false
    } finally {
      if (inFlight === request) {
        loading.hidden = true
        body.setAttribute("aria-busy", "false")
      }
    }
  }
  const navigate = (state: PairState, replace = false) => {
    if (!pairURL(state.wbPair)) return
    if (replace) view.history.replaceState(state, "", state.wbPair)
    else view.history.pushState(state, "", state.wbPair)
    void show(state)
  }
  bench.addEventListener("click", event => {
    const square = (event.target as Element | null)?.closest?.<HTMLAnchorElement>("a.pb-wb-square")
    if (!square || event.defaultPrevented || event.button !== 0) return
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    const url = pairURL(square.href)
    if (!url) return
    const criterion = (event.target as Element).closest<HTMLElement>("[data-wb-criterion]")
    if (criterion?.dataset.wbCriterion) url.searchParams.set("check", criterion.dataset.wbCriterion)
    event.preventDefault()
    returnFocus = square
    navigate({wbPair: url.pathname + url.search + url.hash, title: square.dataset.wbPair!})
  })
  // Run history and set selectors stay inside this dialog/history entry.
  dialog.addEventListener("click", event => {
    const link = (event.target as Element | null)?.closest?.<HTMLAnchorElement>("a")
    if (!link || event.defaultPrevented || event.button !== 0) return
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    const hash = link.getAttribute("href")
    if (hash?.startsWith("#")) {
      const section = body.querySelector<HTMLElement>(`#${CSS.escape(hash.slice(1))}`)
      if (!section) return
      event.preventDefault()
      section.scrollIntoView({block: "start", behavior: "instant"})
      const state = view.history.state as PairState | null
      const url = state?.wbPair && pairURL(state.wbPair)
      if (url) {
        url.hash = hash
        view.history.replaceState({...state, wbPair: url.pathname + url.search + hash}, "", url.href)
        page.href = url.href
      }
      return
    }
    if (!link.hasAttribute("data-wb-open-run") || !pairURL(link.href)) return
    event.preventDefault()
    navigate({wbPair: link.href, title: title.textContent || "Recorded run"}, true)
  })
  dialog.addEventListener("submit", event => {
    const form = event.target as HTMLFormElement
    if (form.method.toLowerCase() !== "get") return
    const url = pairURL(form.action)
    if (!url) return
    event.preventDefault()
    url.search = ""
    for (const [key, value] of new FormData(form)) if (typeof value === "string" && value) url.searchParams.set(key, value)
    navigate({wbPair: url.href, title: title.textContent || "Recorded runs"}, true)
  })
  dialog.addEventListener("close", () => {
    inFlight?.abort()
    if (!closingFromHistory && (view.history.state as PairState | null)?.wbPair) view.history.back()
    returnFocus?.focus({preventScroll: true})
    closingFromHistory = false
  })
  showPair = state => {
    if (!state?.wbPair || !pairURL(state.wbPair)) return false
    void show(state)
    return true
  }
  view.addEventListener("popstate", () => {
    if (dialog.open) { closingFromHistory = true; dialog.close() }
  })
}

let showPair: ((state: PairState | null) => boolean) | null = null

/**
 * The history entries the bench's dialog pushes are its own. LiveView loads
 * any other address reached by Back or Forward as a new page, so this has to
 * be listening before LiveView connects: listeners on the window run in the
 * order they were added, and LiveView never hears about these entries.
 */
export function claimWalletBenchHistory(view: Window) {
  view.addEventListener("popstate", event => {
    if (showPair?.(event.state as PairState | null)) event.stopImmediatePropagation()
  })
}

/** The line under the board names the square or dot under the pointer or focus. */
function mountStatus(bench: HTMLElement) {
  const viewport = bench.querySelector<HTMLElement>("[data-wb-viewport]")
  const status = bench.querySelector<HTMLElement>("[data-wb-hover]")
  if (!viewport) return
  const describe = (target: EventTarget | null) => {
    const element = target as Element | null
    const dot = element?.closest?.<HTMLElement>("[data-wb-dot-label]")
    const cell = element?.closest?.<HTMLAnchorElement>("a.pb-wb-square")
    if (status) status.textContent = dot?.dataset.wbDotLabel || cell?.dataset.wbSummary || "Select a square to see its run."
  }
  viewport.addEventListener("pointerover", event => describe(event.target))
  viewport.addEventListener("focusin", event => describe(event.target))
}

// A Filter choice left at "Any recorded version" stays out of the address it
// sends. Back to this page from the browser's memory, every choice is usable
// again.
function keepFilterAddressShort(doc: Document) {
  const filter = doc.getElementById("pb-wb-filter")
  if (!filter) return
  const selects = Array.from(filter.querySelectorAll<HTMLSelectElement>("select"))
  filter.querySelector("form")?.addEventListener("submit", () => {
    for (const select of selects) if (select.value === "") select.disabled = true
  })
  doc.defaultView?.addEventListener("pageshow", () => {
    for (const select of selects) select.disabled = false
  })
}
