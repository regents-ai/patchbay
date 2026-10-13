/**
 * The Offer slot rails on /offers. A rail first scrolled into view boots in,
 * its tiles stepping in from the left; one already on screen when the page
 * arrives is simply there. Pointing at the slot for sale sweeps a scan line
 * across it, once each time the pointer arrives.
 */
import {createScope, stagger, type Scope} from "animejs"
import {BASE, EASE_OUT, SLOW, play, still} from "./motion/shared.ts"
import {onFirstSight} from "./motion/reveals.ts"
import type {Hook} from "../hook_composition.ts"

type SlotsHook = {el: HTMLElement; scope?: Scope}

export const OfferSlots: Hook = {
  mounted(this: SlotsHook) {
    const rail = this.el
    const scope = createScope({root: rail})

    this.scope = scope.add(self => {
      self!.add("boot", () =>
        play([...rail.querySelectorAll("[data-slot]")], {
          x: {from: -12},
          opacity: {from: 0},
          duration: BASE,
          delay: stagger(50),
          ease: EASE_OUT,
        }),
      )
      self!.add("scan", (scan: Element) =>
        play(scan, {
          x: ["-100%", "260%"],
          opacity: [{to: 1, duration: 80}, {to: 0, delay: 80, duration: 120}],
          duration: SLOW,
          ease: EASE_OUT,
        }),
      )

      // pointerenter does not bubble, so the rail hears each tile's on the way down.
      const sweep = (event: PointerEvent) => {
        const tile = event.target
        if (event.pointerType !== "mouse" || !(tile instanceof HTMLElement) || !tile.matches("[data-open]")) return
        const scan = tile.querySelector("[data-scan]")
        if (scan && !still(rail)) scope.methods.scan(scan)
      }
      rail.addEventListener("pointerenter", sweep, true)

      const unwatch = onFirstSight(rail, () => {
        if (!still(rail)) scope.methods.boot()
      })

      return () => {
        rail.removeEventListener("pointerenter", sweep, true)
        unwatch()
      }
    })
  },

  destroyed(this: SlotsHook) {
    this.scope?.revert()
  },
}
