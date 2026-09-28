const WAIT_MS = 300

type SearchOptions = {document?: Document; fetch?: typeof globalThis.fetch}

/**
 * The Search field at the top of the discussions. As the person types, the
 * discussions under it narrow to what matches, with the sites and tools by
 * that name above them, and the address follows so the page can be shared
 * or reloaded as it is. Pressing Enter searches the ordinary way.
 */
export function mountDiscussionSearch(options: SearchOptions = {}) {
  const doc = options.document ?? globalThis.document
  const form = doc?.getElementById?.("pb-search") as HTMLFormElement | null
  const field = form?.elements.namedItem("q") as HTMLInputElement | null
  if (!form || !field) return

  const fetcher = options.fetch ?? globalThis.fetch
  let timer: ReturnType<typeof setTimeout> | undefined
  let inFlight: AbortController | null = null

  const look = async () => {
    const address = searchAddress(new FormData(form))
    inFlight?.abort()
    inFlight = new AbortController()
    try {
      const response = await fetcher(address, {
        headers: {accept: "text/html"},
        credentials: "same-origin",
        signal: inFlight.signal,
      })
      if (!response.ok) return
      const page = new DOMParser().parseFromString(await response.text(), "text/html")
      const found = page.getElementById("pb-results")
      const shown = doc.getElementById("pb-results")
      if (!found || !shown) return
      shown.replaceWith(doc.importNode(found, true))
      globalThis.history?.replaceState?.(null, "", address)
    } catch {
      // The list stays as it was; pressing Enter still searches.
    }
  }

  field.addEventListener("input", () => {
    clearTimeout(timer)
    timer = setTimeout(look, WAIT_MS)
  })
}

/** The home page address for what the search form holds, leaving out what is empty. */
export function searchAddress(fields: Iterable<[string, FormDataEntryValue]>) {
  const query = new URLSearchParams()
  for (const [name, value] of fields) {
    if (typeof value === "string" && value.trim() !== "") query.set(name, value.trim())
  }
  const text = query.toString()
  return text === "" ? "/" : `/?${text}`
}
