import type {ValuePanel} from "../panel"

/** Sites: the index panel, a wall of sites lit as a check sweeps across them. */
export const sites: ValuePanel = {
  colours: ["#06332b", "#2fbfa0", "#dcfff5"],
  pitch: [10, 10],
  stillAt: 4.6,
  body: /* wgsl */ `
  let cycle = t * 0.12;
  let lap = floor(cycle);
  let sweep = fract(cycle) * 1.3 - 0.15;
  let level = hash(g.id + vec2f(lap * 3.0, 11.0));
  let has = step(0.3, level);
  let done = step(x, sweep);
  let edge = exp(-sq((x - sweep) * 16.0));
  let near = p.z * (1.0 - smoothstep(0.05, 0.12, length((g.at - p.xy) * aspect())));
  let amount = max(max(has * mix(0.16, 0.35 + 0.6 * level, done), edge * 0.85), near);
  let tone = max(has * mix(0.2, 0.3 + 0.6 * level, done), max(edge * 0.95, near));
  return emit(g, sdBox(g.local, vec2f(3.6, 3.6), 1.5), ramp(tone), amount);
`,
}
