/**
 * Draws the home page's activity strip with WebGPU through vgpu, on a clear
 * canvas over the activity box: rows of small squares in the page's line
 * colour, and a wave of its accent that runs across them once each time
 * `pulse` is called. Loaded only once the strip is really going to be drawn.
 * Nothing here moves by itself: at rest the strip is one still frame, the
 * same squares the server drew (`.pb-pulse-still` in home.css).
 */
import {prepareShader} from "@vgpu/wgsl/prepare"
import {effect, frame, init, surface} from "vgpu"

import type {IslandRenderer} from "../canvas_island.ts"

/** Red, green and blue from 0 to 1, as the screen shows them. */
export type Rgb = readonly [number, number, number]

/** The squares' colour at rest, and the colour the wave lights them. */
export type PulseColours = {ink: Rgb; accent: Rgb}

export type ActivityPulseRenderer = IslandRenderer & {
  /** The colours the next frame is drawn in. */
  paint(colours: PulseColours): void
  /** Starts a wave across the strip, over again if one is running. */
  pulse(): void
}

/** The frames a wave takes: within the 24 the island gives an easing, 370 ms at 60 a second. */
export const PULSE_FRAMES = 22

// The grid is in CSS pixels from the top left, as the still face draws it:
// squares 4 wide on an 8 pixel pitch. The wave is about 56 pixels across.
const wgsl = /* wgsl */ `
struct Params {
  // The frame's width and height, frame pixels for each CSS pixel, and how far
  // the wave has run, 0 at rest.
  size: vec4f,
  ink: vec4f,
  accent: vec4f,
}
@group(0) @binding(0) var<uniform> params: Params;

const PITCH = 8.0;
const HALF = 2.0;
const BAND = 56.0;
const PI = 3.14159265;

// A 0..1 value for a whole-numbered place, by integer arithmetic so every GPU agrees.
fn hash(p: vec2f) -> f32 {
  let q = vec2u(vec2i(floor(p)));
  var n = (q.x * 1597334677u) ^ (q.y * 3812015801u);
  n = (n ^ (n >> 16u)) * 2246822519u;
  n = n ^ (n >> 13u);
  return f32(n >> 8u) / 16777216.0;
}

@fragment fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let scale = params.size.z;
  let at = uv * params.size.xy / scale;
  let cell = floor(at / PITCH);
  let centre = cell * PITCH + vec2f(HALF);
  let d = max(abs(at.x - centre.x), abs(at.y - centre.y)) - HALF;
  let cover = clamp(0.5 - d * scale, 0.0, 1.0);

  // The wave's front eases from off the left edge to off the right one, each
  // square a little early or late, and the whole wave swells and fades.
  let t = params.size.w;
  let width = params.size.x / scale;
  let front = mix(-BAND, width + BAND, 1.0 - (1.0 - t) * (1.0 - t));
  let off = (centre.x - front + (hash(cell) - 0.5) * 16.0) / (BAND * 0.5);
  let lit = exp(-off * off) * sin(t * PI) * (0.65 + 0.35 * hash(cell + vec2f(7.0, 3.0)));

  let colour = mix(params.ink.rgb, params.accent.rgb, clamp(lit, 0.0, 1.0));
  return vec4f(colour * cover, cover);
}
`

const rgba = (colour: Rgb): [number, number, number, number] => [colour[0], colour[1], colour[2], 1]

export async function createActivityPulseRenderer(
  canvas: HTMLCanvasElement,
  size: readonly [number, number],
  onDeviceLost: () => void,
): Promise<ActivityPulseRenderer> {
  const gpu = await init()
  let disposed = false
  // Disposing the device resolves the same promise, so only a strip still on
  // screen reports a loss.
  void gpu.lost.then(() => {
    if (!disposed) onDeviceLost()
  })

  try {
    const stage = surface(gpu, canvas, {autoResize: false, alphaMode: "premultiplied", label: "activity-pulse"})
    stage.resize([size[0], size[1]])
    const shader = effect(gpu, prepareShader(wgsl, "activity_pulse.wgsl"), {label: "activity-pulse.pass"})
    await shader.compile(stage)

    // Given by the strip's script before the first frame (`paint`).
    let colours: PulseColours | undefined
    // Frames into the running wave, none at rest.
    let at: number | undefined

    return {
      paint(next) {
        colours = next
      },
      pulse() {
        at = 0
      },
      resize(width, height) {
        stage.resize([width, height])
      },
      step(snap) {
        if (at === undefined) return false
        at = snap ? PULSE_FRAMES : at + 1
        if (at >= PULSE_FRAMES) at = undefined
        return true
      },
      present() {
        if (!colours) return
        const [width, height] = stage.size
        shader.set({
          params: {
            size: [width, height, width / canvas.clientWidth, at === undefined ? 0 : at / PULSE_FRAMES],
            ink: rgba(colours.ink),
            accent: rgba(colours.accent),
          },
        })
        frame(gpu, current => current.pass({target: stage, clear: [0, 0, 0, 0]}, shader))
      },
      settled() {
        return gpu.settled()
      },
      dispose() {
        if (disposed) return
        disposed = true
        stage.dispose()
        gpu.dispose()
      },
    }
  } catch (error) {
    gpu.dispose()
    throw error
  }
}
