/**
 * Motion for moving between views and for a page arriving: tabs whose
 * underline travels to the chosen tab, a headline that writes itself in and a
 * grid of cards that settles into place.
 */
import {animate, createScope, spring, splitText, stagger, utils} from "animejs"
import {EASE_IN_OUT, EASE_OUT, SLOW, byPointer, onReplay, still} from "./shared.js"

// How the underline travels and how the new panel arrives. `step` is 1 when
// the chosen tab is to the right of the last one and -1 when it is to the left.
const TABS = {
  glide: {
    ink: (from, to) => ({...to, duration: SLOW, ease: EASE_IN_OUT}),
    panel: step => ({x: {from: step * 24}, opacity: {from: 0}, duration: SLOW, ease: EASE_OUT}),
  },
  // The underline stretches to cover both tabs, then lets go of the old one.
  stretch: {
    ink: (from, to, base) => {
      const left = Math.min(from.x, to.x)
      const right = Math.max(from.x + from.scaleX * base, to.x + to.scaleX * base)
      return {
        x: [{to: left, duration: 140}, {to: to.x, duration: 180}],
        scaleX: [{to: (right - left) / base, duration: 140}, {to: to.scaleX, duration: 180}],
        ease: "inOut(2)",
      }
    },
    panel: () => ({y: {from: 10}, opacity: {from: 0}, duration: SLOW, ease: EASE_OUT}),
  },
  spring: {
    ink: (from, to) => ({...to, ease: spring({bounce: 0.35, duration: 360})}),
    panel: () => ({scale: {from: 0.96}, opacity: {from: 0}, ease: spring({bounce: 0.3, duration: 320})}),
  },
}

/**
 * Tabs the server switches. The underline keeps the position this island
 * gives it across page updates; the panel is a new element for each tab, so it
 * always starts from its natural look.
 */
export const PatchbayTabs = {
  mounted() {
    const scope = createScope({root: this.el})
    this.active = this.el.dataset.active
    this.pointer = false

    this.scope = scope.add(() => {
      const ink = this.el.querySelector("[data-ink]")
      const tabs = [...this.el.querySelectorAll("[data-tab]")]
      const tab = name => tabs.find(el => el.dataset.tab === name)
      const spot = name => ({x: tab(name).offsetLeft, scaleX: tab(name).offsetWidth / ink.offsetWidth})

      scope.add("place", () => utils.set(ink, spot(this.el.dataset.active)))

      scope.add("move", (from, to) => {
        const style = TABS[this.el.dataset.variant]
        animate(ink, style.ink(spot(from), spot(to), ink.offsetWidth))
        const step = tabs.indexOf(tab(to)) > tabs.indexOf(tab(from)) ? 1 : -1
        animate(this.el.querySelector("[role=tabpanel]"), style.panel(step))
      })

      const onClick = event => {
        if (event.target.closest("[data-tab]") !== null) this.pointer = byPointer(event)
      }
      const watch = new ResizeObserver(() => scope.methods.place())

      scope.methods.place()
      watch.observe(this.el)
      this.el.addEventListener("click", onClick, true)
      return () => {
        watch.disconnect()
        this.el.removeEventListener("click", onClick, true)
      }
    })
  },

  updated() {
    const from = this.active
    const to = this.el.dataset.active
    this.active = to
    if (from === to) return

    if (this.pointer && !still(this.el)) this.scope.methods.move(from, to)
    else this.scope.methods.place()
    this.pointer = false
  },

  destroyed() {
    this.scope?.revert()
  },
}

// Moves in percent name both ends, so they stay a share of each piece's own
// height instead of being converted to pixels from its width.
export const HEADLINES = {
  rise: split =>
    animate(split.words, {y: ["100%", "0%"], delay: stagger(50), duration: SLOW, ease: EASE_OUT}),
  cascade: split =>
    animate(split.chars, {
      y: ["-100%", "0%"],
      rotate: {from: -20},
      opacity: {from: 0},
      delay: stagger(16),
      duration: SLOW,
      ease: "outBack(1.8)",
    }),
  type: split =>
    animate(split.chars, {opacity: {from: 0}, delay: stagger(24), duration: 60, ease: "linear"}),
}

export const GRIDS = {
  cascade: cards =>
    animate(cards, {y: {from: 16}, opacity: {from: 0}, delay: stagger(45), duration: SLOW, ease: EASE_OUT}),
  bloom: cards =>
    animate(cards, {
      scale: {from: 0.8},
      opacity: {from: 0},
      delay: stagger(60, {grid: true, from: "center"}),
      ease: spring({bounce: 0.4, duration: 360}),
    }),
  drop: cards =>
    animate(cards, {
      y: {from: -40},
      rotate: {from: (_el, i) => (i % 2 ? 6 : -6)},
      opacity: {from: 0},
      delay: stagger(40, {from: "random"}),
      duration: 420,
      ease: "outBack(1.6)",
    }),
}

/**
 * An entrance the island owns outright: the page never patches inside it
 * and only keeps `data-variant` current. It plays when the island mounts,
 * when the variant changes, when its own replay button is pressed and when
 * the page asks every island to replay.
 */
const entrance = (variants, pieces) => ({
  mounted() {
    const scope = createScope({root: this.el})
    this.variant = this.el.dataset.variant

    this.scope = scope.add(() => {
      const targets = pieces(this.el)

      scope.add("play", () => {
        if (!still(this.el)) variants[this.el.dataset.variant](targets)
      })

      const onClick = event => {
        if (event.target.closest("[data-replay]") !== null) scope.methods.play()
      }
      const stopReplay = onReplay(() => scope.methods.play())

      scope.methods.play()
      this.el.addEventListener("click", onClick)
      return () => {
        stopReplay()
        this.el.removeEventListener("click", onClick)
      }
    })
  },

  updated() {
    if (this.el.dataset.variant === this.variant) return
    this.variant = this.el.dataset.variant
    this.scope.methods.play()
  },

  destroyed() {
    this.scope?.revert()
  },
})

export const PatchbayHeadline = entrance(HEADLINES, el =>
  splitText(el.querySelector("[data-headline]"), {words: {wrap: "clip"}, chars: true}),
)

export const PatchbayCascade = entrance(GRIDS, el => [...el.querySelectorAll("[data-card]")])
