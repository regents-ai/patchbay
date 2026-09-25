/**
 * What every motion island on Patchbay shares: the design system's timings and
 * curves, one Scope per island, and the two questions each one asks before it
 * moves anything.
 */
import {createScope, cubicBezier} from "animejs"

export const FAST = 140
export const BASE = 200
export const SLOW = 280

export const EASE_OUT = cubicBezier(0.23, 1, 0.32, 1)
export const EASE_IN_OUT = cubicBezier(0.77, 0, 0.175, 1)

// The two Patchbay colours that sparks, stitches and rings are drawn in.
export const SPARK_COLORS = ["var(--palette-tangerine-tango)", "var(--palette-powder-blue)"]

export function motionScope(root) {
  return createScope({root, mediaQueries: {reduced: "(prefers-reduced-motion: reduce)"}})
}

// The reader asked for less motion, either in their system settings or with a
// switch on the page around the island.
export function calm(scope, el) {
  return scope.matches.reduced || el.closest("[data-motion='reduced']") !== null
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
