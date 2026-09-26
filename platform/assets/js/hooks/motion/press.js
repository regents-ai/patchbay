/**
 * Small answers to a mouse or finger press. The button still does its job the
 * instant it is pressed; the motion only plays alongside it. A press from the
 * keyboard, or a reader who asked for less motion, gets no motion at all.
 *
 * Squish is Patchbay's standard press and nope its standard answer when
 * something is refused; every page uses them from `motion.js`. The lab's
 * other presses are named with `data-press`. Sparks, pings and stitches are
 * removed as soon as they finish.
 */
import {animate, createScope, random, stagger} from "animejs"
import {EASE_OUT, byPointer, play, still} from "./shared.js"
import {spawn, sweep, sweepAll} from "./fx.js"

// Both end where they began, then hand the element back to its stylesheet,
// so a hover or press style that moves it still can. One pressed again
// mid-move starts over from rest.
export const squish = el =>
  play(el, {scale: [{to: 0.9, duration: 90, ease: "out(3)"}, {to: 1, duration: 360, ease: "outBack(3)"}]})

export const nope = el => play(el, {x: [0, -7, 6, -4, 2, 0], duration: 380, ease: "inOut(2)"})

// Something was refused. Unlike a press, the shake plays however the refused
// thing was asked for, because it is the answer, not decoration.
export function deny(el) {
  if (!still(el)) nope(el)
}

export const PatchbayPress = {
  mounted() {
    const scope = createScope({root: this.el})

    const PRESSES = {
      squish,

      jelly: button =>
        play(button, {
          scaleX: [1, 1.2, 0.9, 1.05, 0.98, 1],
          scaleY: [1, 0.82, 1.1, 0.96, 1.02, 1],
          duration: 560,
          ease: "inOut(2)",
        }),

      nope,

      sparks: (button, x, y) => {
        squish(button)
        const sparks = spawn(this.el, 10, "pb-fx-spark", x, y)
        const flights = sparks.map((_spark, i) => {
          const angle = (i / sparks.length) * Math.PI * 2 + random(-0.25, 0.25, 2)
          const reach = random(26, 54)
          return {x: Math.cos(angle) * reach, y: Math.sin(angle) * reach}
        })
        animate(sparks, {
          x: (_el, i) => flights[i].x,
          y: (_el, i) => flights[i].y,
          scale: [1, 0],
          duration: 520,
          ease: "out(4)",
          onComplete: sweep(sparks),
        })
      },

      ping: (button, x, y) => {
        squish(button)
        const rings = spawn(this.el, 2, "pb-fx-ring", x, y)
        animate(rings, {
          scale: [0.2, 3.2],
          opacity: [0.7, 0],
          delay: stagger(110),
          duration: 560,
          ease: EASE_OUT,
          onComplete: sweep(rings),
        })
      },

      stitches: (button, x, y) => {
        squish(button)
        const stitches = spawn(this.el, 5, "pb-fx-stitch", x, y)
        for (const stitch of stitches) stitch.textContent = "+"
        animate(stitches, {
          x: () => random(-28, 28),
          y: () => random(-64, -34),
          rotate: () => random(-120, 120),
          scale: [0.2, 1.2, 0.7],
          opacity: [1, 1, 0],
          delay: stagger(35),
          duration: 700,
          ease: "out(3)",
          onComplete: sweep(stitches),
        })
      },
    }

    this.scope = scope.add(() => {
      scope.add("press", (kind, button, x, y) => PRESSES[kind](button, x, y))

      const onClick = event => {
        const button = event.target.closest("[data-press]")
        if (button === null || !byPointer(event) || still(this.el)) return
        scope.methods.press(button.dataset.press, button, event.clientX, event.clientY)
      }

      this.el.addEventListener("click", onClick)
      return () => {
        this.el.removeEventListener("click", onClick)
        sweepAll(this.el)
      }
    })
  },

  destroyed() {
    this.scope?.revert()
  },
}
