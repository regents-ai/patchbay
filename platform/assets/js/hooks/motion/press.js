/**
 * Small answers to a mouse or finger press. The button still does its job the
 * instant it is pressed; the motion only plays alongside it. A press from the
 * keyboard, or a reader who asked for less motion, gets no motion at all.
 *
 * Each button names its answer with `data-press`. Sparks, pings and stitches
 * are removed as soon as they finish.
 */
import {animate, random, stagger} from "animejs"
import {EASE_OUT, byPointer, calm, motionScope} from "./shared.js"
import {spawn, sweep, sweepAll} from "./fx.js"

export const PatchbayPress = {
  mounted() {
    const scope = motionScope(this.el)

    const PRESSES = {
      squish: button =>
        animate(button, {
          scale: [{to: 0.9, duration: 90, ease: "out(3)"}, {to: 1, duration: 360, ease: "outBack(3)"}],
        }),

      jelly: button =>
        animate(button, {
          scaleX: [1, 1.2, 0.9, 1.05, 0.98, 1],
          scaleY: [1, 0.82, 1.1, 0.96, 1.02, 1],
          duration: 560,
          ease: "inOut(2)",
        }),

      nope: button =>
        animate(button, {
          x: [0, -7, 6, -4, 2, 0],
          duration: 380,
          ease: "inOut(2)",
        }),

      sparks: (button, x, y) => {
        PRESSES.squish(button)
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
        PRESSES.squish(button)
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
        PRESSES.squish(button)
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
        if (button === null || !byPointer(event) || calm(scope, this.el)) return
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
