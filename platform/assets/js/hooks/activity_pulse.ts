/**
 * The home page's activity strip (`PatchbayWeb.Forum.BoardHTML.activity_pulse/1`)
 * on the canvas island (`activity_pulse/renderer.ts`). It rests as still
 * squares and, each time a post arrives in the list it names in `data-list`
 * (`posts:arrived`, from `PatchbayWeb.PostListLive`), a wave of colour runs
 * across it once. Its colours are the page's own, read from the strip's
 * stylesheet: its `color` for the squares and its `border-color` for the wave,
 * and read again when the theme changes. A visitor who asked for less motion,
 * or whose browser cannot draw it, keeps the still squares the server drew.
 */
import {createCanvasIsland, type CanvasIslandController} from "../canvas_island.ts"
import {watchTheme} from "../theme.ts"
import type {ActivityPulseRenderer, PulseColours, Rgb} from "../activity_pulse/renderer.ts"

type ActivityPulseHook = {
  el: HTMLElement
  island?: CanvasIslandController
  handleEvent(event: string, callback: (payload: {list: string}) => void): void
}

// Any colour the stylesheet resolves, as the screen shows it, through a
// one-pixel canvas.
function colourReader() {
  const canvas = document.createElement("canvas")
  canvas.width = 1
  canvas.height = 1
  const context = canvas.getContext("2d", {willReadFrequently: true})!
  return (css: string): Rgb => {
    context.clearRect(0, 0, 1, 1)
    context.fillStyle = css
    context.fillRect(0, 0, 1, 1)
    const [r, g, b] = context.getImageData(0, 0, 1, 1).data
    return [r / 255, g / 255, b / 255]
  }
}

export const ActivityPulse = {
  mounted(this: ActivityPulseHook) {
    const strip = this.el
    const read = colourReader()
    const colours = (): PulseColours => {
      const style = getComputedStyle(strip)
      return {ink: read(style.color), accent: read(style.borderTopColor)}
    }
    let pulse = () => {}

    this.island = createCanvasIsland<ActivityPulseRenderer>(strip, {}, {
      canvasSelector: "[data-activity-pulse-canvas]",
      readyFlag: "activityPulseReady",
      motionSensitive: true,
      continuous: false,
      maxDevicePixelRatio: 2,
      browserLoad: async (canvas, size, onDeviceLost) => {
        const {createActivityPulseRenderer} = await import("../activity_pulse/renderer.ts")
        return createActivityPulseRenderer(canvas, size, onDeviceLost)
      },
      interact({renderer, nudge, onReady}) {
        const repaint = () => {
          renderer()?.paint(colours())
          nudge()
        }
        onReady(() => renderer()?.paint(colours()))
        pulse = () => {
          renderer()?.pulse()
          nudge()
        }
        const unwatch = watchTheme(repaint)
        return () => {
          pulse = () => {}
          unwatch()
        }
      },
    })
    this.island.mount()

    this.handleEvent("posts:arrived", ({list}) => {
      if (list === strip.dataset.list) pulse()
    })
  },
  disconnected(this: ActivityPulseHook) {
    this.island?.pause()
  },
  reconnected(this: ActivityPulseHook) {
    this.island?.resume()
  },
  destroyed(this: ActivityPulseHook) {
    this.island?.destroy()
  },
}
