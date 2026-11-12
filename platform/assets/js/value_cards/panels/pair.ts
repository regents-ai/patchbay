import type {ValuePanel} from "../panel"

/** Agents: the pair panel, an agent and its person joined by a line that carries signals. */
export const pair: ValuePanel = {
  colours: ["#3e1704", "#f08a24", "#ffe6c8"],
  pitch: [9, 9],
  stillAt: 2,
  body: /* wgsl */ `
  let asp = aspect();
  let bob = 0.025 * sin(t * 0.9);
  let one = vec2f(0.29, 0.45 + bob);
  let two = mix(vec2f(0.71, 0.5 - bob), p.xy, p.z);
  let q1 = (g.at - one) * asp;
  let q2 = (g.at - two) * asp;
  let drop = select(length(q1) - 0.15, max(abs(q1.x) - 0.15 * (1.0 - q1.y / 0.28), q1.y - 0.28), q1.y > 0.0);
  let in1 = 1.0 - smoothstep(-0.01, 0.012, drop);
  let in2 = 1.0 - smoothstep(-0.01, 0.012, sdBox(q2, vec2f(0.14, 0.14), 0.06));
  let eye = min(sdBox(q1 - vec2f(-0.055, 0.015), vec2f(0.014, 0.034), 0.0), sdBox(q1 - vec2f(0.055, 0.015), vec2f(0.014, 0.034), 0.0));
  let eyes = in1 * (1.0 - step(0.0, eye));
  let ab = (two - one) * asp;
  let k = sat(dot(q1, ab) / dot(ab, ab));
  let wire = (1.0 - smoothstep(0.01, 0.026, length(q1 - ab * k))) * (1.0 - max(in1, in2));
  let pulse = exp(-sq((fract(k * 2.0 - t * 0.45) - 0.5) * 6.0));
  let value = max(max(max(in1 * 0.88, in2 * 0.76), wire * (0.22 + 0.78 * pulse)), eyes);
  let tone = max(max(max(in1 * 0.62, in2 * 0.45), wire * (0.3 + 0.7 * pulse)), eyes);
  return emit(g, sdDiamond(g.local, mix(1.2, 4.4, value)), ramp(tone), value);
`,
}
