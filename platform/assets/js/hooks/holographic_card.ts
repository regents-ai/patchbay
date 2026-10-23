import type {
  HolographicCardLook,
  HolographicCardRenderer,
} from "../../vendor/regent_ui/holographic_card.mjs"
import {
  createCanvasIsland,
  type CanvasIslandController,
  type CanvasIslandOptions,
  type LoadRenderer,
  type MediaQuery,
} from "../canvas_island.ts"

export type HolographicCardOptions = CanvasIslandOptions<HolographicCardRenderer> & {
  pointerQuery?: () => MediaQuery
}

/** A computed `rgb(…)` colour as the three 0..1 channels the renderer takes. */
const channels = (color: string): readonly [number, number, number] => {
  const [red = 0, green = 0, blue = 0] = (color.match(/[\d.]+/g) ?? []).map(Number)
  return [red / 255, green / 255, blue / 255]
}

/**
 * What the markup asks of the foil. `data-holo-crown="false"` leaves the crown
 * off a face and `"beside"` keeps it only where it stands clear of the content,
 * `data-holo-shine` scales the light against the account card's, and
 * `data-holo-ink` makes the foil the ink of the line drawing beside the canvas.
 */
const browserLoadCard =
  (root: HTMLElement): LoadRenderer<HolographicCardRenderer> =>
  async (canvas, size, onDeviceLost) => {
    const {createHolographicCardRenderer, holographicInkMask} = await import(
      "../../vendor/regent_ui/holographic_card.mjs"
    )
    const {holoCrown, holoShine} = root.dataset
    const look: HolographicCardLook = {
      crown: holoCrown === "beside" ? "beside" : holoCrown !== "false",
      shine: holoShine === undefined ? 1 : Number(holoShine),
    }
    if ("holoInk" in root.dataset) {
      const drawing = canvas.closest(".rg-technical-figure__art")?.querySelector("svg")
      if (!drawing) throw new Error("foil ink needs the line drawing beside its canvas")
      canvas.style.maskImage = holographicInkMask(drawing)
      look.ink = channels(getComputedStyle(drawing).color)
      const panel = canvas.closest(".rg-panel")
      if (!panel) throw new Error("foil ink needs the panel its drawing sits on")
      look.ground = channels(getComputedStyle(panel, "::after").backgroundColor)
    }
    return createHolographicCardRenderer(canvas, size, onDeviceLost, look)
  }

/**
 * The shared holographic foil, drawn on the island's canvas. The card never
 * moves: the light on its foil follows the pointer. A picture that moves is
 * never drawn for a visitor who asked for less of it, and a pointer that cannot
 * hover never lights the foil.
 */
export const createHolographicCardController = (
  root: HTMLElement,
  options: HolographicCardOptions = {},
): CanvasIslandController => {
  const pointerQuery = options.pointerQuery ?? (() => window.matchMedia("(pointer: fine)"))

  return createCanvasIsland(root, options, {
    canvasSelector: "[data-holo-canvas]",
    readyFlag: "holoReady",
    browserLoad: browserLoadCard(root),
    motionSensitive: true,
    interact({root: card, canvas, renderer, nudge}) {
      // The light falls where the pointer stands against the foil, which may be
      // only part of the card.
      const onPointerMove = (event: PointerEvent) => {
        if (event.isPrimary === false) return
        const {left, top, width, height} = canvas().getBoundingClientRect()
        renderer()?.point([(event.clientX - left) / width, (event.clientY - top) / height])
        nudge()
      }
      const onPointerLeave = () => {
        renderer()?.rest()
        nudge()
      }

      const fine = pointerQuery().matches
      if (fine) {
        card.addEventListener("pointermove", onPointerMove, {passive: true})
        card.addEventListener("pointerleave", onPointerLeave, {passive: true})
      }

      return () => {
        if (fine) {
          card.removeEventListener("pointermove", onPointerMove)
          card.removeEventListener("pointerleave", onPointerLeave)
        }
      }
    },
  })
}

type HolographicCardHook = {
  el: HTMLElement
  controller?: CanvasIslandController
}

export const HolographicCard = {
  mounted(this: HolographicCardHook) {
    this.controller = createHolographicCardController(this.el)
    this.controller.mount()
  },
  disconnected(this: HolographicCardHook) {
    this.controller?.pause()
  },
  reconnected(this: HolographicCardHook) {
    this.controller?.resume()
  },
  destroyed(this: HolographicCardHook) {
    this.controller?.destroy()
    this.controller = undefined
  },
}
