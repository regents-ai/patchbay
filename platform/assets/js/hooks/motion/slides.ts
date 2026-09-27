/**
 * Panels that slide in and out: a drawer from the side, a sheet from the
 * bottom, a menu under its button and a note pinned to the corner. The island
 * owns them outright (the page never patches inside it), so their open state
 * lives here. Which way each one moves is read from `data-<panel>` on the
 * island, which the page does keep current.
 *
 * Every variant of a panel moves the same set of properties and puts all of
 * them back when the panel closes, so switching variants never leaves a
 * stray tilt or offset behind.
 */
import {animate, createScope, spring, stagger, utils, type AnimationParams, type JSAnimation, type Scope} from "animejs"
import type {Hook} from "phoenix_live_view"
import {BASE, EASE_OUT, FAST, SLOW, byPointer, play, still} from "./shared.ts"

const CLOSE = {duration: BASE, ease: "in(3)"}

type Slide = {away: Record<string, number | string>; open: AnimationParams}

const PANELS: Record<string, {backdrop: boolean} & Record<string, Slide | boolean>> = {
  drawer: {
    backdrop: true,
    glide: {away: {x: "100%", rotate: 0}, open: {duration: SLOW, ease: EASE_OUT}},
    spring: {away: {x: "100%", rotate: 0}, open: {ease: spring({bounce: 0.3, duration: 380})}},
    lean: {away: {x: "100%", rotate: 7}, open: {duration: 460, ease: "outBack(1.4)"}},
  },
  sheet: {
    backdrop: true,
    rise: {away: {y: "100%"}, open: {duration: SLOW, ease: EASE_OUT}},
    spring: {away: {y: "100%"}, open: {ease: spring({bounce: 0.35, duration: 400})}},
  },
  menu: {
    backdrop: false,
    pop: {away: {y: -6, scale: 0.9, opacity: 0}, open: {duration: SLOW, ease: "outBack(2.2)"}},
    drop: {away: {y: -14, scale: 1, opacity: 0}, open: {duration: BASE, ease: EASE_OUT}},
  },
  note: {
    backdrop: false,
    peel: {away: {x: -30, y: 24, rotate: -16, scale: 0.6, opacity: 0}, open: {duration: 420, ease: "outBack(2)"}},
    toss: {away: {x: -160, y: -40, rotate: -40, scale: 1, opacity: 0}, open: {ease: spring({bounce: 0.4, duration: 460})}},
  },
}

// Where a panel rests when it is open: no offset, no tilt, full size.
const REST: Record<string, number> = {x: 0, y: 0, rotate: 0, scale: 1, opacity: 1}
const rest = (away: Slide["away"]) => Object.fromEntries(Object.keys(away).map(key => [key, REST[key]]))

export const PatchbaySlides: Hook<{scope: Scope}> = {
  mounted() {
    const scope = createScope({root: this.el})
    const moving = new Map<Element, JSAnimation>()
    const openers = new Map<string, HTMLElement>()

    const panel = (name: string) => this.el.querySelector<HTMLElement>(`[data-panel="${name}"]`)!
    const backdrop = () => this.el.querySelector<HTMLElement>("[data-backdrop]")!
    const variant = (name: string) => PANELS[name][this.el.dataset[name]!] as Slide

    const stop = (el: Element) => {
      moving.get(el)?.pause()
      moving.delete(el)
    }

    const move = (el: Element, params: AnimationParams) => {
      stop(el)
      moving.set(el, animate(el, params))
    }

    const opened = () =>
      Object.keys(PANELS).filter(name => openers.get(name)?.getAttribute("aria-expanded") === "true")

    this.scope = scope.add(() => {
      scope.add("open", (name: string, animated: boolean) => {
        const el = panel(name)
        const {away, open} = variant(name)

        if (el.hidden) {
          el.hidden = false
          utils.set(el, away)
        }

        if (PANELS[name].backdrop) {
          const shade = backdrop()
          if (shade.hidden) {
            shade.hidden = false
            utils.set(shade, {opacity: 0})
          }
          animated ? move(shade, {opacity: 1, duration: BASE, ease: EASE_OUT}) : utils.set(shade, {opacity: 1})
        }

        if (!animated) {
          stop(el)
          utils.set(el, rest(away))
          return
        }

        move(el, {...rest(away), ...open})
        const items = el.querySelectorAll("[data-item]")
        if (items.length > 0) {
          play([...items], {
            opacity: {from: 0},
            y: {from: 10},
            delay: stagger(40, {start: 80}),
            duration: SLOW,
            ease: EASE_OUT,
          })
        }
      })

      scope.add("close", (name: string, animated: boolean) => {
        const el = panel(name)
        const {away} = variant(name)

        const put = () => {
          el.hidden = true
          utils.set(el, rest(away))
        }

        if (PANELS[name].backdrop && !opened().some(other => other !== name && PANELS[other].backdrop)) {
          const shade = backdrop()
          const hide = () => { shade.hidden = true }
          animated ? move(shade, {opacity: 0, duration: FAST, ease: "in(2)", onComplete: hide}) : hide()
        }

        if (!animated) {
          stop(el)
          put()
          return
        }

        move(el, {...away, ...CLOSE, onComplete: put})
      })

      const open = (name: string, opener: HTMLElement, animated: boolean) => {
        openers.set(name, opener)
        scope.methods.open(name, animated)
        panel(name).querySelector<HTMLElement>("[data-close]")?.focus({preventScroll: true})
        opener.setAttribute("aria-expanded", "true")
      }

      const close = (name: string, animated: boolean) => {
        scope.methods.close(name, animated)
        const opener = openers.get(name)
        opener?.setAttribute("aria-expanded", "false")
        opener?.focus({preventScroll: true})
      }

      const onClick = (event: MouseEvent) => {
        const animated = byPointer(event) && !still(this.el)
        const opener = (event.target as Element).closest<HTMLElement>("[data-open]")
        const closer = (event.target as Element).closest("[data-close]")

        if (opener !== null) {
          const name = opener.dataset.open!
          opener.getAttribute("aria-expanded") === "true" ? close(name, animated) : open(name, opener, animated)
        } else if (closer !== null) {
          close(closer.closest<HTMLElement>("[data-panel]")!.dataset.panel!, animated)
        } else if ((event.target as Element).closest("[data-backdrop]") !== null) {
          for (const name of opened()) if (PANELS[name].backdrop) close(name, animated)
        }
      }

      const onKey = (event: KeyboardEvent) => {
        if (event.key !== "Escape") return
        const [last] = opened().slice(-1)
        if (last !== undefined) close(last, false)
      }

      this.el.addEventListener("click", onClick)
      this.el.addEventListener("keydown", onKey)
      return () => {
        this.el.removeEventListener("click", onClick)
        this.el.removeEventListener("keydown", onKey)
      }
    })
  },

  destroyed() {
    this.scope?.revert()
  },
}
