import type {ValuePanel} from "../panel"

/** Bench: the runs panel, one row a run, each filling as it goes and some stopping short. */
export const bench: ValuePanel = {
  colours: ["#0a2850", "#3b93f0", "#e0f0ff"],
  pitch: [9, 12],
  stillAt: 7,
  body: /* wgsl */ `
  let row = g.id.y;
  let seed = hash(vec2f(row, 3.0));
  let run = t * (0.14 + 0.12 * seed) + seed * 6.0;
  let lap = floor(run);
  let fails = step(hash(vec2f(row, lap + 9.0)), 0.32);
  let stopAt = mix(1.02, 0.3 + 0.5 * hash(vec2f(lap, row + 17.0)), fails);
  let front = fract(run) * 1.3;
  let lit = step(x, min(front, stopAt));
  let ended = step(stopAt, front);
  let passed = ended * (1.0 - fails);
  let mark = fails * ended * (1.0 - step(0.6 / g.count.x, abs(x - stopAt)));
  let aim = p.z * (1.0 - step(0.5, abs(row - floor((1.0 - p.y) * g.count.y))));
  let amount = max(lit * (0.3 + 0.45 * passed + 0.2 * aim), max(mark, 0.12 * aim));
  let tone = select(mix(0.25 + 0.35 * x, 0.85, passed) + 0.1 * aim, 0.6, mark > 0.5);
  let shape = mix(sdBox(g.local, vec2f(3.0, 3.4), 0.6), sdSlash(g.local, 3.4, 0.8, 1.0), mark);
  return emit(g, shape, ramp(tone), amount);
`,
}
