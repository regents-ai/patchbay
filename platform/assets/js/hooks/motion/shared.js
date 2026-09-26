/**
 * What all of Patchbay's motion shares: the design system's timings and
 * curves, and the two questions asked before anything moves.
 */
import {animate, cubicBezier, utils} from "animejs"

export const FAST = 140
export const BASE = 200
export const SLOW = 280

export const EASE_OUT = cubicBezier(0.23, 1, 0.32, 1)
export const EASE_IN_OUT = cubicBezier(0.77, 0, 0.175, 1)

// The two Patchbay colours that sparks, stitches and rings are drawn in.
export const SPARK_COLORS = ["var(--palette-tangerine-tango)", "var(--palette-powder-blue)"]

// The reader asked for less motion, either in their system settings or with a
// switch on the page around the element.
export function still(el) {
  return matchMedia("(prefers-reduced-motion: reduce)").matches || el.closest("[data-motion='reduced']") !== null
}

// A click from Enter or Space reports no pointer presses. Keyboard-driven UI
// answers at once rather than animating.
export function byPointer(event) {
  return event.detail > 0
}

// Replay buttons dispatch this on the window, so one press can restart every
// island on the page.
export const REPLAY = "pb-motion:replay"

export function onReplay(callback) {
  window.addEventListener(REPLAY, callback)
  return () => window.removeEventListener(REPLAY, callback)
}

// Anime.js hands an element back to its stylesheet by restoring the inline
// style it found when the animation began. One begun over another's
// half-way frame would end on that frame, so each run first puts its
// elements back as they were before the last run on them began. Every run
// then starts from rest, and ends there with no inline style left behind.
// A finished run is forgotten, so nothing later puts back its old snapshot.
const playing = new WeakMap()

export function play(targets, params) {
  const els = [targets].flat()
  for (const el of els) playing.get(el)?.revert()
  const animation = animate(els, {
    ...params,
    onComplete: done => {
      utils.cleanInlineStyles(done)
      for (const el of els) if (playing.get(el) === done) playing.delete(el)
    },
  })
  for (const el of els) playing.set(el, animation)
  return animation
}
