/**
 * Motion for things the server decides: a list that changes, such as a stack
 * of notes, and a figure that moves. The page renders every result first;
 * these islands only animate from the old picture to the new one.
 */
import {
  animate,
  createLayout,
  createScope,
  spring,
  splitText,
  stagger,
  type AnimationParams,
  type LayoutAnimationParams,
  type Scope,
  type TextSplitter,
} from "animejs"
import {BASE, CLIPPED_CHAR, EASE_OUT, SLOW, play, still} from "./shared.ts"
import {deny} from "./press.ts"
import {composeHooks, type Hook} from "../../hook_composition.ts"

// How a list moves when the server adds, reorders or drops its items: `bounce`
// for lists and `pop` for notes that come and go. A new item only fades in
// where it lands: a slide or a scale in its entrance stays written on it as
// `translate: none` once it settles. Each is built fresh per change because a
// stagger remembers the items it measured.
export const LAYOUTS: Record<string, () => LayoutAnimationParams> = {
  bounce: () => ({
    ease: spring({bounce: 0.35, duration: 420}),
    enterFrom: {opacity: 0},
    leaveTo: {opacity: 0, transform: "scale(.9)", ease: "in(3)", duration: BASE},
  }),
  pop: () => ({
    ease: spring({bounce: 0.45, duration: 360}),
    enterFrom: {opacity: 0},
    leaveTo: {opacity: 0, transform: "scale(.8)", ease: "in(3)", duration: BASE},
  }),
}

type ListHook = {el: HTMLElement; scope?: Scope}

/**
 * A list the server owns, built from a table of versions. It renders
 * `data-layout-id` on the list and on every item, names the items in
 * `data-children` and the version in `data-variant`. An item that is leaving
 * is hidden for a moment before the server drops it, so it can fade out while
 * its neighbours close the gap.
 */
export const listHook = (layouts: Record<string, () => LayoutAnimationParams>): Hook => ({
  mounted(this: ListHook) {
    const scope = createScope({root: this.el})

    this.scope = scope.add(() => {
      const layout = createLayout(this.el, {children: this.el.dataset.children})
      scope.add("record", () => layout.record())
      scope.add("move", () => layout.animate(layouts[this.el.dataset.variant ?? ""]()))
    })
  },

  beforeUpdate(this: ListHook) {
    this.scope?.methods.record()
  },

  updated(this: ListHook) {
    if (!still(this.el)) this.scope?.methods.move()
  },

  destroyed(this: ListHook) {
    this.scope?.revert()
  },
})

export const MotionList = listHook(LAYOUTS)

// What the reader was reading before the server changed the list, by how far
// it was from the top of the screen: the field they were typing in; or, once
// they have scrolled past the list's start, each item still on the screen or
// below it, in order, and the end of the list. While the list starts on the
// screen nothing is kept, so the reader sees what arrives.
type Place = {typing: [HTMLElement, number]} | {items: [HTMLElement, number][]; end: number}
// The page scrolls by whole pixels and rows need not be whole pixels tall, so
// what a move could not make up, under a pixel, is `owed` to the next one
// while the reader stays where the last one left them, at `rest`.
type ArrivalsHook = {el: HTMLElement; seen: Set<string>; place?: Place; owed: number; rest?: number}

// The items of a list the server keeps current, each with an id: the
// element's children, or those `data-arrivals` names.
const items = (root: HTMLElement) =>
  [...root.querySelectorAll<HTMLElement>(root.dataset.arrivals ?? ":scope > *")]

const top = (el: Element) => el.getBoundingClientRect().top

function place(root: HTMLElement): Place | undefined {
  const focused = document.activeElement
  if (
    focused instanceof HTMLElement && root.contains(focused) && focused.matches("input, textarea, select") &&
    top(focused) >= 0 && top(focused) < innerHeight
  ) {
    return {typing: [focused, top(focused)]}
  }
  // A list scrolled to its start sits at the top of the screen to within a
  // pixel, as rows need not stop on whole pixels.
  const box = root.getBoundingClientRect()
  if (box.top >= 1) return undefined
  return {
    items: items(root)
      .filter(item => item.getBoundingClientRect().bottom > 0)
      .map(item => [item, top(item)]),
    end: box.bottom,
  }
}

// How far what the reader was reading moved: the field they are typing in;
// otherwise the first item they could see that is still in the list, or else
// everything after the list. What arrives above the screen, or changes size
// there, moves it; what arrives lower down does not.
function moved(root: HTMLElement, was: Place) {
  if ("typing" in was) return was.typing[0].isConnected ? top(was.typing[0]) - was.typing[1] : 0
  const kept = was.items.find(([item]) => root.contains(item))
  return kept ? top(kept[0]) - kept[1] : root.getBoundingClientRect().bottom - was.end
}

/**
 * A list that others add to and change while the reader watches, such as new
 * posts or replies. What arrives settles in where it lands, rising a few
 * pixels as it fades in; nothing around it moves, so the page shifts only by
 * its height. A reader scrolled past the list's start, or typing in a field
 * in it, keeps what they were reading where it was on the screen whatever
 * arrives or changes size above it, as a browser that anchors its scrolling
 * does, in every browser. What was there when the list was drawn stays
 * still, and so does an item drawn again.
 */
export const MotionArrivals: Hook = {
  mounted(this: ArrivalsHook) {
    this.seen = new Set(items(this.el).map(item => item.id))
  },

  beforeUpdate(this: ArrivalsHook) {
    this.place = place(this.el)
    if (scrollY !== this.rest) this.owed = 0
  },

  updated(this: ArrivalsHook) {
    const shift = this.place ? moved(this.el, this.place) + this.owed : 0
    const from = scrollY
    if (shift !== 0) scrollBy({top: shift, behavior: "instant"})
    const left = shift - (scrollY - from)
    this.owed = Math.abs(left) < 1 ? left : 0
    this.rest = scrollY

    const now = items(this.el)
    const arrived = now.filter(item => !this.seen.has(item.id))
    this.seen = new Set(now.map(item => item.id))
    if (arrived.length > 0 && !still(this.el)) {
      play(arrived, {y: {from: 6}, opacity: {from: 0}, duration: BASE, ease: EASE_OUT})
    }
  },
}

// How the digits that changed arrive. `clip` masks each digit in its own
// slot, so a digit rolling in is hidden until it reaches the slot.
export type Roll = {clip: boolean; move: (up: boolean) => AnimationParams}

export const ROLLS: Record<string, Roll> = {
  roll: {clip: true, move: up => ({y: [up ? "100%" : "-100%", "0%"], duration: SLOW, ease: "outBack(1.4)"})},
  // A balance that changed while the reader watches: the new digits flash in.
  flash: {clip: false, move: () => ({opacity: [0, 1, 0.35, 1], scale: [1.35, 1], duration: SLOW * 3, ease: "outQuad"})},
}

// What a figure is worth, decimals included, so 1.75 to 2 rolls up.
const worth = (text: string) => Number(text.replace(/[^\d.]/g, ""))

// A figure's characters as the split makes them, which leaves out spaces, so
// a figure with a unit such as "12.5 USDC" lines up digit for digit.
const glyphs = (figure: HTMLElement) => (figure.textContent ?? "").replace(/\s/g, "")

// The figures inside a part of the page, each marked `data-count`, or those
// `data-figures` names.
const figures = (root: HTMLElement) =>
  [...root.querySelectorAll<HTMLElement>(root.dataset.figures ?? "[data-count]")]

type CountHook = {el: HTMLElement; scope?: Scope; before?: Map<HTMLElement, string>; splits: Set<TextSplitter>}

// Put the plain figure back, but only for a split that is still on the page:
// an older one would write its stale figure over the new one.
function join(hook: CountHook, split: TextSplitter) {
  if (!hook.splits.delete(split)) return
  split.revert()
}

/**
 * Figures the server changes, built from a table of versions. A figure may
 * carry a unit, such as "12.5 USDC". Only the characters that changed move,
 * the ones nearest the end first, like a counter turning over. The figure is
 * split into pieces for the move and joined back as soon as it ends, so the
 * page always patches the plain figure it rendered. A figure the change
 * brings, such as a reply's first like or a new reply's figures, is simply
 * there, and the figures that were already there still roll.
 */
export const countHook = (rolls: Record<string, Roll>): Hook => ({
  mounted(this: CountHook) {
    const scope = createScope({root: this.el})
    this.splits = new Set()

    this.scope = scope.add(() => {
      scope.add("roll", (split: TextSplitter, digits: HTMLElement[], up: boolean) => {
        animate(digits, {
          ...rolls[this.el.dataset.variant ?? ""].move(up),
          delay: stagger(45, {from: "last"}),
          onComplete: () => join(this, split),
        })
      })
    })
  },

  beforeUpdate(this: CountHook) {
    for (const split of this.splits) join(this, split)
    this.before = new Map(figures(this.el).map(figure => [figure, glyphs(figure)]))
  },

  updated(this: CountHook) {
    if (still(this.el)) return

    const {clip} = rolls[this.el.dataset.variant ?? ""]
    for (const figure of figures(this.el)) {
      // A figure that was not on the page before is simply there.
      const was = this.before?.get(figure)
      const now = glyphs(figure)
      if (was === undefined || was === now) continue

      const split = splitText(figure, {words: false, chars: clip ? CLIPPED_CHAR : true})
      const digits = split.chars.filter((_char, i) => was.at(i - now.length) !== now[i])
      this.splits.add(split)
      this.scope?.methods.roll(split, digits, worth(now) > worth(was))
    }
  },

  destroyed(this: CountHook) {
    for (const split of this.splits) join(this, split)
    this.scope?.revert()
  },
})

export const MotionCount = countHook(ROLLS)

// A thread others reply to and like while the reader watches: its replies
// settle in and its counts roll.
export const MotionThread = composeHooks(MotionArrivals, MotionCount)

type RefusalHook = {el: HTMLElement; scope?: Scope; said?: string}

/**
 * A message a live page shows when it refuses something. It shakes once when
 * it appears and again whenever it says something new, while `data-refused`
 * is on it. A shake still playing when the message goes stops with it. Pages
 * the server draws once shake their alerts from `motion.ts`.
 */
export const MotionRefusal: Hook = {
  mounted(this: RefusalHook) {
    const scope = createScope({root: this.el})
    this.said = this.el.textContent ?? ""

    this.scope = scope.add(() => {
      scope.add("shake", () => {
        if (this.el.dataset.refused !== undefined) deny(this.el)
      })
      scope.methods.shake()
    })
  },

  updated(this: RefusalHook) {
    const said = this.el.textContent ?? ""
    if (said !== this.said) this.scope?.methods.shake()
    this.said = said
  },

  destroyed(this: RefusalHook) {
    this.scope?.revert()
  },
}
