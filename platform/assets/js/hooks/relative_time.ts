/**
 * How long ago something happened, worked out in the browser.
 *
 * The server renders the clock time in a `datetime` attribute, which never goes
 * stale, and this turns it into the words the board uses. Doing it here means a
 * page that sits open keeps counting instead of freezing on whatever the last
 * diff happened to say.
 */
import type {Hook, HookInterface} from "phoenix_live_view"

const MINUTE = 60
const HOUR = 60 * MINUTE
const DAY = 24 * HOUR
const WEEK = 7 * DAY
const MONTH = 30 * DAY
const YEAR = 365 * DAY

const REFRESH_MS = 30_000

export function inWords(datetime: string | null, now = Date.now()) {
  const at = Date.parse(datetime as string)
  if (Number.isNaN(at)) return ""

  const seconds = Math.floor((now - at) / 1000)

  if (seconds < MINUTE) return "just now"
  if (seconds < HOUR) return count(seconds, MINUTE, "minute")
  if (seconds < DAY) return count(seconds, HOUR, "hour")
  if (seconds < WEEK) return count(seconds, DAY, "day")
  if (seconds < MONTH) return count(seconds, WEEK, "week")
  if (seconds < YEAR) return count(seconds, MONTH, "month")
  return count(seconds, YEAR, "year")
}

function count(seconds: number, unit: number, word: string) {
  const whole = Math.floor(seconds / unit)
  return `${whole} ${word}${whole === 1 ? "" : "s"} ago`
}

type RelativeTime = {
  timer: ReturnType<typeof setInterval>
  say(this: RelativeTime & HookInterface): void
}

export const PatchbayRelativeTime: Hook<RelativeTime> = {
  mounted() {
    this.say()
    this.timer = setInterval(() => this.say(), REFRESH_MS)
  },

  updated() {
    this.say()
  },

  destroyed() {
    clearInterval(this.timer)
  },

  say(this: RelativeTime & HookInterface) {
    const words = inWords(this.el.getAttribute("datetime"))
    if (words) this.el.textContent = words
  },
}
