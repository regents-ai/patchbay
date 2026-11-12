import type {ValuePanel} from "../panel"

/** Fixes: the mend panel, broken slashes drawn whole into a tick. */
export const fixes: ValuePanel = {
  colours: ["#22104e", "#8b5cf6", "#f0e8ff"],
  pitch: [9, 9],
  stillAt: 4.8,
  body: /* wgsl */ `
  let asp = aspect();
  let c = g.at * asp;
  let a = vec2f(0.24, 0.52) * asp;
  let b = vec2f(0.42, 0.33) * asp;
  let e = vec2f(0.77, 0.7) * asp;
  let ba = b - a;
  let eb = e - b;
  let h1 = sat(dot(c - a, ba) / dot(ba, ba));
  let h2 = sat(dot(c - b, eb) / dot(eb, eb));
  let d1 = length(c - a - ba * h1);
  let d2 = length(c - b - eb * h2);
  let along = select(length(ba) + h2 * length(eb), h1 * length(ba), d1 < d2);
  let cycle = fract(t * 0.15);
  let drawn = smoothstep(0.02, 0.4, cycle) * (length(ba) + length(eb));
  let fade = 1.0 - smoothstep(0.9, 1.0, cycle);
  let width = 1.0 - smoothstep(0.03, 0.055, min(d1, d2));
  let mend = width * step(along, drawn) * fade;
  let head = width * exp(-sq((along - drawn) * 24.0)) * fade * step(cycle, 0.45);
  let near = p.z * exp(-sq(length((g.at - p.xy) * asp) * 9.0));
  let value = sat(max(max(mend * 0.82, head), near * 0.8));
  let shape = mix(sdSlash(g.local, 2.6, 0.6, 1.0), sdBox(g.local, vec2f(3.3, 3.3), 0.8), sat(value * 1.6));
  return emit(g, shape, ramp(0.15 + 0.85 * value), max(value, 0.24));
`,
}
