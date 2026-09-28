const CHECK_PATH = "/fix-check"
const WAIT_MS = 800
const CHECKING = "Looking for WebMCP tools at this address…"

// Answers that keep the free fix's button from being pressed.
const LOCKED = new Set<string | undefined>(["none", "limited", "unreachable", "invalid"])

export type SiteTool = {name: string; description: string}

export type SiteAnswer = {status: string; said?: string; tools?: SiteTool[]; directory?: boolean}

type SiteField = {value: string; addEventListener(type: "input" | "change", listener: () => void): void}

type SiteCheckForm = {
  dataset: DOMStringMap
  elements: Record<string, SiteField | undefined>
  querySelector(selector: "#pb-fix-site-check"): {textContent: string; dataset: DOMStringMap} | null
  querySelector(selector: "#pb-fix-submit"): {disabled: boolean} | null
  querySelector(selector: "#pb-fix-directory"): {hidden: boolean; dataset: DOMStringMap} | null
}

type Fetcher = (url: string, init: RequestInit) => Promise<Pick<Response, "json">>

type SiteCheckOptions = {
  fetch?: Fetcher
  setTimeout?: (callback: () => void, ms: number) => number
  clearTimeout?: (timer: number | null) => void
  onTools?: (tools: SiteTool[]) => void
}

/**
 * The quiet look for WebMCP tools at the site's address: as soon as an
 * address is typed, Patchbay says under the field what it found and hands
 * the tools on to be listed, and after a second address without tools the
 * WebMCP Site Directory is offered. Each address is asked about once per
 * page. Only a free fix is held back: its button cannot be pressed for an
 * address without tools. A paid fix is never held back.
 */
export function mountSiteCheck(form: SiteCheckForm, options: SiteCheckOptions = {}) {
  const free = form.dataset.pbFixMode === "free"
  const field = form.elements["fix[site_url]"]
  const line = form.querySelector("#pb-fix-site-check")
  const submit = form.querySelector("#pb-fix-submit")
  const directory = form.querySelector("#pb-fix-directory")
  if (!field || !line || !submit) return null

  const fetcher = options.fetch ?? globalThis.fetch
  const later = options.setTimeout ?? globalThis.setTimeout
  const cancel = options.clearTimeout ?? (globalThis.clearTimeout as (timer: number | null) => void)
  const asked = new Map<string, Promise<SiteAnswer>>()
  let timer: number | null = null

  const show = (answer: SiteAnswer | null) => {
    line.textContent = answer?.said ?? ""
    if (answer) line.dataset.pbCheck = answer.status
    else delete line.dataset.pbCheck
    if (free) submit.disabled = LOCKED.has(answer?.status)
    if (answer?.status !== "checking") options.onTools?.(answer?.tools ?? [])
    if (answer?.directory && directory?.hidden) {
      directory.hidden = false
      directory.dataset.pbArrived = "true"
    }
  }

  const check = async () => {
    cancel(timer)
    const address = field.value.trim()
    if (!addressLike(address)) return show(null)

    let answer = asked.get(address)
    if (!answer) {
      answer = ask(fetcher, address)
      asked.set(address, answer)
    }
    show({status: "checking", said: CHECKING})

    const answered = await answer
    // A wait or a failure is for now, not for the address: ask again later.
    if (answered.status === "limited" || answered.status === "failed") asked.delete(address)
    if (field.value.trim() !== address) return
    show(answered.status === "failed" ? null : answered)
  }

  field.addEventListener("input", () => {
    cancel(timer)
    timer = later(check, WAIT_MS)
  })
  field.addEventListener("change", () => void check())
  if (field.value.trim() !== "") void check()

  return {check}
}

/**
 * Whether what is in the field is a whole web address yet, worth asking
 * about: a named site, not the first letters of one. An address with no
 * scheme is read as https, as Patchbay reads it.
 */
export function addressLike(address: string) {
  try {
    const url = new URL(address.includes("://") ? address : `https://${address}`)
    return (url.protocol === "https:" || url.protocol === "http:") && /\.[a-z0-9-]{2,}$/i.test(url.hostname)
  } catch {
    return false
  }
}

async function ask(fetcher: Fetcher, address: string): Promise<SiteAnswer> {
  try {
    const response = await fetcher(`${CHECK_PATH}?site_url=${encodeURIComponent(address)}`, {
      headers: {accept: "application/json"},
      credentials: "same-origin",
    })
    const body = await response.json()
    return typeof body?.status === "string" && typeof body.said === "string" ? body : {status: "failed"}
  } catch {
    return {status: "failed"}
  }
}
