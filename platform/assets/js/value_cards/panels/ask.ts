import type {ValuePanel} from "../panel"

/** Ask: the beacon panel, a question going out in square rings and answers lighting on them. */
export const ask: ValuePanel = {
  colours: ["#0e1d57", "#3f6cf0", "#e6edff"],
  pitch: [10, 10],
  stillAt: 3,
  body: /* wgsl */ `
  let src = mix(vec2f(0.5, 0.42), p.xy, p.z);
  let q = abs((g.at - src) * aspect());
  let r = max(q.x, q.y);
  let wave = fract(r * 4.2 - t * 0.36);
  let band = min(wave, 1.0 - wave);
  let ring = exp(-sq(band * 6.5)) * (1.0 - smoothstep(0.3, 0.85, r));
  let reply = step(0.88, hash(g.id + vec2f(7.0, floor(t * 0.8)))) * step(0.5, ring);
  let core = 1.0 - smoothstep(0.035, 0.07, r);
  let value = sat(max(max(core, ring * 0.72), reply));
  return emit(g, sdPlus(g.local, mix(1.3, 3.8, value), mix(0.5, 1.1, value)), ramp(0.12 + 0.88 * value), value);
`,
}
