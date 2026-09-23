const CHECK_PATH = "/fix-check"
const WAIT_MS = 800
const CHECKING = "Looking for WebMCP tools at this address…"

// Answers that keep the free fix's button from being pressed.
const LOCKED = new Set(["none", "limited", "unreachable", "invalid"])

/**
 * The quiet look for WebMCP tools at the site's address, on a form offering
 * a free fix: as soon as an address is typed, Patchbay says under the field
 * what it found, the button cannot be pressed for an address without tools,
 * and after a second such address the WebMCP Site Directory is offered. Each
 * address is asked about once per page. A paid fix is never held back, so
 * the form only looks while the fix is free.
 *
 * @param {HTMLFormElement} form
 * @param {{fetch?: typeof globalThis.fetch, setTimeout?: typeof globalThis.setTimeout, clearTimeout?: typeof globalThis.clearTimeout}} [options]
 * @returns {{check: () => Promise<void>} | null}
 */
export function mountSiteCheck(form, options = {}) {
  if (form.dataset.pbFixMode !== "free") return null
  const field = form.elements["fix[site_url]"]
  const line = form.querySelector("#pb-fix-site-check")
  const submit = form.querySelector("#pb-fix-submit")
  const directory = form.querySelector("#pb-fix-directory")
  if (!field || !line || !submit) return null

  const fetcher = options.fetch ?? globalThis.fetch
  const later = options.setTimeout ?? globalThis.setTimeout
  const cancel = options.clearTimeout ?? globalThis.clearTimeout
  const asked = new Map()
  let timer = null

  const show = answer => {
    line.textContent = answer?.said ?? ""
    if (answer) line.dataset.pbCheck = answer.status
    else delete line.dataset.pbCheck
    submit.disabled = LOCKED.has(answer?.status)
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
 * about: a named site, not the first letters of one.
 *
 * @param {string} address
 */
export function addressLike(address) {
  try {
    const url = new URL(address)
    return (url.protocol === "https:" || url.protocol === "http:") && /\.[a-z0-9-]{2,}$/i.test(url.hostname)
  } catch {
    return false
  }
}

async function ask(fetcher, address) {
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
