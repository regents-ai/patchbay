type WalletBenchOptions = {document?: Document; fetch?: typeof globalThis.fetch}
type PairState = {wbPair: string; title: string}

/** A zoomable matrix with a progressively enhanced, full-screen result page. */
export function mountWalletBench(options: WalletBenchOptions = {}) {
  const doc = options.document ?? globalThis.document
  const bench = doc?.getElementById?.("patchbay-wallet-bench")
  if (!bench || bench.dataset.wbMounted) return
  bench.dataset.wbMounted = "true"
  keepFilterAddressShort(doc)
  mountZoom(bench)
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
  view.addEventListener("popstate", event => {
    const state = event.state as PairState | null
    if (state?.wbPair && pairURL(state.wbPair)) void show(state)
    else if (dialog.open) { closingFromHistory = true; dialog.close() }
  })
}

/** Resize real table cells; labels and controls keep their normal text size. */
function mountZoom(bench: HTMLElement) {
  const viewport = bench.querySelector<HTMLElement>("[data-wb-viewport]")
  const table = viewport?.querySelector<HTMLTableElement>("table")
  const slider = bench.querySelector<HTMLInputElement>("[data-wb-zoom]")
  const output = bench.querySelector<HTMLOutputElement>("[data-wb-zoom-value]")
  const status = bench.querySelector<HTMLElement>("[data-wb-hover]")
  if (!viewport || !table || !slider || !output) return
  const base = 104
  let zoom = 100
  const resize = (value: number, centerX = viewport.clientWidth / 2, centerY = viewport.clientHeight / 2) => {
    const next = Math.max(50, Math.min(250, Math.round(value)))
    if (!Number.isFinite(next)) return
    const labelWidth = table.tHead?.rows[0]?.cells[0]?.getBoundingClientRect().width || 0
    const headerHeight = table.tHead?.getBoundingClientRect().height || 0
    const x = Math.max(labelWidth, centerX), y = Math.max(headerHeight, centerY)
    const ratio = next / zoom
    const left = (viewport.scrollLeft + x - labelWidth) * ratio - x + labelWidth
    const top = (viewport.scrollTop + y - headerHeight) * ratio - y + headerHeight
    zoom = next
    viewport.style.setProperty("--pb-wb-cell", `${base * zoom / 100}px`)
    viewport.style.setProperty("--pb-wb-dot", `${Math.max(7, 12 * zoom / 100)}px`)
    viewport.style.setProperty("--pb-wb-dot-gap", `${Math.max(5, 8 * zoom / 100)}px`)
    viewport.dataset.zoomDetail = String(zoom >= 150)
    slider.value = String(zoom)
    output.value = `${zoom}%`
    output.textContent = `${zoom}%`
    viewport.scrollLeft = Math.max(0, left)
    viewport.scrollTop = Math.max(0, top)
    bench.querySelector<HTMLButtonElement>("[data-wb-zoom-out]")!.disabled = zoom === 50
    bench.querySelector<HTMLButtonElement>("[data-wb-zoom-in]")!.disabled = zoom === 250
  }
  slider.addEventListener("input", () => resize(Number(slider.value)))
  bench.querySelector("[data-wb-zoom-out]")?.addEventListener("click", () => resize(zoom - 25))
  bench.querySelector("[data-wb-zoom-in]")?.addEventListener("click", () => resize(zoom + 25))
  bench.querySelector("[data-wb-fit]")?.addEventListener("click", () => {
    const columns = (table.tHead?.rows[0]?.cells.length || 1) - 1
    const labelWidth = table.tHead?.rows[0]?.cells[0]?.getBoundingClientRect().width || 0
    if (columns > 0) resize((viewport.clientWidth - labelWidth - 2) / (columns * base) * 100)
    viewport.scrollLeft = 0
    viewport.scrollTop = 0
  })
  // Ordinary wheel/trackpad scrolling pans; Ctrl/Command-wheel zooms the board.
  viewport.addEventListener("wheel", event => {
    if (!event.ctrlKey && !event.metaKey) return
    event.preventDefault()
    const box = viewport.getBoundingClientRect()
    resize(zoom * Math.exp(-event.deltaY * 0.005), event.clientX - box.left, event.clientY - box.top)
  }, {passive: false})
  const describe = (target: EventTarget | null) => {
    const element = target as Element | null
    const dot = element?.closest?.<HTMLElement>("[data-wb-dot-label]")
    const cell = element?.closest?.<HTMLAnchorElement>("a.pb-wb-square")
    if (status) status.textContent = dot?.dataset.wbDotLabel || cell?.dataset.wbSummary || "Select a square to inspect its recorded run."
  }
  viewport.addEventListener("pointerover", event => describe(event.target))
  viewport.addEventListener("focusin", event => describe(event.target))
  resize(100)
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
