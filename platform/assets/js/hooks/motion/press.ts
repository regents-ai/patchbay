/**
 * Answers to a press. The control still does its job the instant it is
 * pressed, wallet buttons included; the motion only plays alongside it. Both
 * end where they began, then hand the element back to its stylesheet, so a
 * hover style that moves it still can. One pressed again mid-move starts over
 * from rest.
 */
import {EASE_OUT, play, still} from "./shared.ts"

// The standard press: a quick dip and straight back, with no overshoot, done
// in 140 ms, so a button pressed many times a day answers and is still again.
export const tap = (el: Element) =>
  play(el, {scale: [{to: 0.96, duration: 60, ease: EASE_OUT}, {to: 1, duration: 80, ease: EASE_OUT}]})

export const nope = (el: Element) =>
  play(el, {x: [0, -7, 6, -4, 2, 0], duration: 380, ease: "inOut(2)"})

// Something was refused. Unlike a press, the shake plays however the refused
// thing was asked for, because it is the answer, not decoration.
export function deny(el: Element) {
  if (!still(el)) nope(el)
}
