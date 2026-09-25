/**
 * Motion for things the server decides: a list that changes, a number that
 * moves and a thread that is marked solved. The page renders every result
 * first; these islands only animate from the old picture to the new one.
 */
import {animate, createDrawable, createLayout, spring, splitText, stagger} from "animejs"
import {BASE, EASE_IN_OUT, EASE_OUT, SLOW, calm, motionScope} from "./shared.js"
import {centre, spawn, sweep, sweepAll} from "./fx.js"

// How a list moves when the server adds, reorders or hides its items. Each
// is built fresh per change because a stagger remembers the items it measured.
const LAYOUTS = {
  rise: () => ({
    duration: SLOW,
    ease: EASE_OUT,
    enterFrom: {opacity: 0, transform: "translateY(18px) scale(.96)"},
    leaveTo: {opacity: 0, transform: "translateY(-10px) scale(.96)"},
  }),
  pop: () => ({
    ease: spring({bounce: 0.45, duration: 360}),
    enterFrom: {opacity: 0, transform: "scale(.6)"},
    leaveTo: {opacity: 0, transform: "scale(.8)", ease: "in(3)", duration: BASE},
  }),
  side: () => ({
    duration: SLOW,
    ease: EASE_IN_OUT,
    enterFrom: {opacity: 0, transform: "translateX(64px)"},
    leaveTo: {opacity: 0, transform: "translateX(64px)"},
  }),
  glide: () => ({
    duration: 360,
    ease: EASE_IN_OUT,
    enterFrom: {opacity: 0, transform: "scale(.9)"},
    leaveTo: {opacity: 0, transform: "scale(.9)"},
  }),
  bounce: () => ({
    ease: spring({bounce: 0.35, duration: 420}),
    enterFrom: {opacity: 0, transform: "translateY(-12px)"},
    leaveTo: {opacity: 0, transform: "scale(.9)", ease: "in(3)", duration: BASE},
  }),
  ripple: () => ({
    duration: SLOW,
    ease: EASE_IN_OUT,
    delay: stagger(35),
    enterFrom: {opacity: 0, transform: "translateX(-16px)"},
    leaveTo: {opacity: 0, transform: "translateX(16px)"},
  }),
}

/**
 * A list the server owns. It renders `data-layout-id` on the list and on
 * every item, and hides an item for a moment before dropping it, so the item
 * can fade out while its neighbours close the gap.
 */
export const PatchbayLayout = {
  mounted() {
    const scope = motionScope(this.el)

    this.scope = scope.add(() => {
      const layout = createLayout(this.el, {children: this.el.dataset.children})
      scope.add("record", () => layout.record())
      scope.add("glide", () => layout.animate(LAYOUTS[this.el.dataset.variant]()))
    })
  },

  beforeUpdate() {
    this.scope.methods.record()
  },

  updated() {
    if (!calm(this.scope, this.el)) this.scope.methods.glide()
  },

  destroyed() {
    this.scope?.revert()
  },
}

// How the digits that changed arrive. `wrap` masks each digit in its own
// slot, so a digit rolling in is hidden until it reaches the slot. Moves in
// percent name both ends: given only a start, Anime.js would convert it to
// pixels from the digit's width rather than its height.
const ROLLS = {
  roll: {wrap: true, move: up => ({y: [up ? "100%" : "-100%", "0%"], duration: SLOW, ease: "outBack(1.4)"})},
  tick: {wrap: true, move: up => ({y: [up ? "60%" : "-60%", "0%"], opacity: {from: 0}, ease: spring({bounce: 0.55, duration: 300})})},
  pop: {wrap: false, move: () => ({scale: {from: 1.9}, opacity: {from: 0}, duration: SLOW, ease: EASE_OUT})},
}

const worth = text => Number(text.replace(/\D/g, ""))

/**
 * A number the server changes. Only the digits that changed move, the ones
 * nearest the end first, like a counter turning over. The digits are split
 * into pieces for the move and joined back as soon as it ends, so the page
 * always patches the plain number it rendered.
 */
export const PatchbayCounter = {
  mounted() {
    const scope = motionScope(this.el)

    this.scope = scope.add(() => {
      scope.add("roll", (split, digits, up) => {
        animate(digits, {
          ...ROLLS[this.el.dataset.variant].move(up),
          delay: stagger(45, {from: "last"}),
          onComplete: () => this.join(split),
        })
      })
    })
  },

  beforeUpdate() {
    this.join(this.split)
    this.before = this.el.textContent
  },

  updated() {
    const before = this.before
    const after = this.el.textContent
    if (before === after || calm(this.scope, this.el)) return

    const {wrap} = ROLLS[this.el.dataset.variant]
    const split = splitText(this.el, {words: false, chars: wrap ? {wrap: "clip"} : true})
    const digits = split.chars.filter((_char, i) => before.at(i - after.length) !== after[i])
    this.split = split
    this.scope.methods.roll(split, digits, worth(after) > worth(before))
  },

  destroyed() {
    this.join(this.split)
    this.scope?.revert()
  },

  // Put the plain number back, but only for the split that is still on the
  // page: an older one would write its stale number over the new one.
  join(split) {
    if (split === undefined || split !== this.split) return
    split.revert()
    this.split = undefined
  },
}

// How the stamp lands once the server has marked the thread solved.
const STAMPS = {
  thunk: (card, stamp) => {
    animate(stamp, {scale: {from: 2.4}, rotate: {from: -24}, opacity: {from: 0}, duration: 240, ease: "in(3)"})
    animate(card, {y: [0, 5, -1, 0], delay: 220, duration: 260, ease: "out(2)"})
    return 260
  },
  ink: (_card, stamp) => {
    animate(stamp, {scale: {from: 1.15}, opacity: {from: 0}, duration: BASE, ease: EASE_OUT})
    return 120
  },
  party: (card, stamp) => {
    animate(stamp, {scale: {from: 0}, rotate: {from: 40}, ease: spring({bounce: 0.5, duration: 420})})
    const [x, y] = centre(stamp)
    const stitches = spawn(card, 8, "pb-fx-stitch", x, y)
    for (const stitch of stitches) stitch.textContent = "+"
    animate(stitches, {
      x: (_el, i) => Math.cos((i / stitches.length) * Math.PI * 2) * 70,
      y: (_el, i) => Math.sin((i / stitches.length) * Math.PI * 2) * 48,
      rotate: (_el, i) => (i % 2 ? 1 : -1) * 90,
      scale: [0.2, 1.1, 0.6],
      opacity: [1, 1, 0],
      delay: 80,
      duration: 640,
      ease: "out(3)",
      onComplete: sweep(stitches),
    })
    return 180
  },
}

/**
 * A thread card that is stamped solved. The page renders the stamp, then
 * tells the island the thread was just solved, so a page opened on a thread
 * that was already solved shows the stamp without any fuss.
 */
export const PatchbayStamp = {
  mounted() {
    const scope = motionScope(this.el)

    this.scope = scope.add(() => {
      scope.add("stamp", () => {
        const stamp = this.el.querySelector("[data-stamp]")
        const inkAt = STAMPS[this.el.dataset.variant](this.el, stamp)
        const [tick] = createDrawable(stamp.querySelector("[data-tick]"))
        animate(tick, {draw: ["0 0", "0 1"], delay: inkAt, duration: SLOW, ease: EASE_OUT})
      })

      return () => sweepAll(this.el)
    })

    this.handleEvent("motion:solved", () => {
      if (!calm(this.scope, this.el)) this.scope.methods.stamp()
    })
  },

  destroyed() {
    this.scope?.revert()
  },
}
