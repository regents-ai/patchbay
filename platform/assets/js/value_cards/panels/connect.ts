import type {ValuePanel} from "../panel"

/** Connect: the patch panel, two rows of jacks and the cords between them carrying signals. */
export const connect: ValuePanel = {
  colours: ["#16181f", "#8c95a8", "#f6f7fa"],
  pitch: [8, 8],
  stillAt: 3,
  body: /* wgsl */ `
  let jacks = 6.0;
  let slope = g.count.y / g.count.x;
  let u = sat((x - 0.13) / 0.74);
  let span = step(0.13, x) * step(x, 0.87);
  var value = 0.0;
  var tone = 0.0;
  for (var i = 0; i < 4; i++) {
    let k = f32(i);
    let life = t * 0.08 + k * 0.29;
    let lap = floor(life);
    let shown = smoothstep(0.0, 0.08, fract(life)) * (1.0 - smoothstep(0.92, 1.0, fract(life)));
    let ya = (floor(hash(vec2f(k, lap)) * jacks) + 0.5) / jacks;
    let yb = (floor(hash(vec2f(k + 9.0, lap)) * jacks) + 0.5) / jacks;
    let cy = mix(ya, yb, smoothstep(0.0, 1.0, u)) - 0.07 * sin(u * 3.1415927);
    let dcy = ((yb - ya) * 6.0 * u * (1.0 - u) - 0.07 * 3.1415927 * cos(u * 3.1415927)) / 0.74;
    let off = abs(y - cy) * g.count.y / sqrt(1.0 + sq(dcy * slope));
    let cord = (1.0 - smoothstep(0.45, 1.1, off)) * span * shown;
    let pulse = exp(-sq((fract(u * 1.5 - t * 0.35 - k * 0.31) - 0.5) * 6.0));
    let lit = cord * (0.3 + 0.7 * pulse);
    if (lit > value) {
      value = lit;
      tone = 0.35 + 0.07 * k + 0.45 * pulse;
    }
  }
  let port = (1.0 - step(0.045, abs(abs(x - 0.5) - 0.42))) * (1.0 - step(0.2, abs(fract(y * jacks) - 0.5)));
  let held = p.z * (1.0 - smoothstep(0.04, 0.1, length((g.at - p.xy) * aspect())));
  value = max(max(value, port * 0.55), held);
  tone = max(tone, max(port * 0.5, held));
  return emit(g, length(g.local) - mix(0.9, 3.2, value), ramp(tone), value);
`,
}
