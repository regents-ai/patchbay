/**
 * Patchbay's standard motion on every page: a squish when something is
 * pressed, a shake when the answer is no, the page's headline rising in word
 * by word and its lists of cards settling into place. The motion lab at
 * /animations keeps the other versions that were tried.
 *
 * A live page draws its own parts again whenever it changes, so only what the
 * server drew once moves as the page opens; live lists move from their hooks.
 */
import {splitText} from "animejs"
import {byPointer, still} from "./hooks/motion/shared.js"
import {deny, nope, squish} from "./hooks/motion/press.js"
import {GRIDS, HEADLINES} from "./hooks/motion/reveals.js"

const PRESSABLE = "button, .rg-button, [role='button']"

// The first cards of a list cascade in; later ones start below the fold and
// are simply there.
const CASCADE = 12

const live = el => el.closest("[data-phx-session]") !== null

export function mountMotion(doc = document) {
  doc.addEventListener("click", press)

  const main = doc.querySelector("main")
  if (main === null || live(main) || still(main)) return

  const headline = main.querySelector("h1")
  if (headline !== null) rise(headline)

  for (const list of main.querySelectorAll("[data-cascade]")) GRIDS.cascade([...list.children].slice(0, CASCADE))

  // A form the server sent back refused says why, and the reason shakes once.
  for (const reason of main.querySelectorAll("[role='alert']")) deny(reason)
}

// The lab's own presses, named with `data-press`, answer for themselves. A
// button that says it cannot be used yet shakes its head instead.
function press(event) {
  const el = event.target.closest(PRESSABLE)
  if (el === null || el.closest("[data-press]") !== null || !byPointer(event) || still(el)) return
  if (el.getAttribute("aria-disabled") === "true") nope(el)
  else squish(el)
}

// The words are joined back into plain text once they have risen.
function rise(headline) {
  const split = splitText(headline, {words: {wrap: "clip"}})
  HEADLINES.rise(split).then(() => split.revert())
}
