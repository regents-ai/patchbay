/**
 * The Offer slot rails on /offers. A rail first scrolled into view boots in,
 * its tiles stepping in from the left; one already on screen when the page
 * arrives is simply there.
 */
import {createScope, stagger, type Scope} from "animejs"
import {BASE, EASE_OUT, play, still} from "./motion/shared.ts"
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
      const unwatch = onFirstSight(rail, () => {
        if (!still(rail)) scope.methods.boot()
      })

      return unwatch
    })
  },

  destroyed(this: SlotsHook) {
    this.scope?.revert()
  },
}
