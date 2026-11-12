// Invariant: the knob's position scrubs the theme switch's swarm of blocks. At
// night every block is on the moon and by day on the sun, square on the grid;
// in between the swarm is part way, some blocks home, some in flight and
// tumbling, some still waiting, in the order they leave, clockwise from the
// bottom. The knob can be moved back and forth and the swarm follows exactly.
import assert from "node:assert/strict"
import {describe, it} from "node:test"
import {createMorph, departureOrder, MOST_QUARTER_TURNS, PIXEL_STRIDE, SWIRL_TURNS} from "../../js/theme_switch/morph.ts"
import {pairByAngle, pixelsOf, turnBetween, wrapAngle, type Cell} from "../../js/theme_switch/pixels.ts"

const cellsOf = (rows: readonly string[]): Cell[] =>
  rows.flatMap((line, row) => [...line].flatMap((mark, col) => (mark === "#" ? [{col, row}] : [])))

// A crescent with three stars and a sun, 33 blocks each on a 9 by 9 grid.
const MOON = [
  "...##..#.",
  "..##.....",
  ".##....#.",
  ".##..#...",
  "###......",
  "###.....#",
  ".###...##",
  "..######.",
  "...####..",
]
const SUN = [
  "#...#...#",
  ".#.....#.",
  "...###...",
  "..#####..",
  "#.#####.#",
  "..#####..",
  "...###...",
  ".#.....#.",
  "#...#...#",
]
const PAIRS = pairByAngle(pixelsOf(cellsOf(MOON), 9), pixelsOf(cellsOf(SUN), 9))
const morph = createMorph(PAIRS)
const out = new Float32Array(PAIRS.length * PIXEL_STRIDE)

/** Every block where knob position `p` puts it: x, y, its turn and share of day. */
function at(p: number) {
  morph.seek(p)
  morph.write(out)
  return PAIRS.map((_, i) => {
    const o = i * PIXEL_STRIDE
    return {x: out[o], y: out[o + 1], spin: out[o + 2], day: out[o + 3]}
  })
}

const offSquare = (spin: number) => Math.abs(spin / (Math.PI / 2) - Math.round(spin / (Math.PI / 2)))

describe("the swarm at either end", () => {
  it("has as many pictures' worth of blocks as it was given", () => {
    assert.equal(PAIRS.length, 33)
  })

  it("sits on the moon at night, every block square", () => {
    at(0).forEach((pixel, i) => {
      assert.ok(Math.abs(pixel.x - PAIRS[i].moon.x) < 10 ** -5 / 2)
      assert.ok(Math.abs(pixel.y - PAIRS[i].moon.y) < 10 ** -5 / 2)
      assert.equal(pixel.spin, 0)
      assert.equal(pixel.day, 0)
    })
  })

  it("sits on the sun by day, every block landed square after its tumble", () => {
    at(1).forEach((pixel, i) => {
      assert.ok(Math.abs(pixel.x - PAIRS[i].sun.x) < 10 ** -4 / 2)
      assert.ok(Math.abs(pixel.y - PAIRS[i].sun.y) < 10 ** -4 / 2)
      assert.ok(Math.abs(pixel.spin - (morph.tumbles[i] * Math.PI) / 2) < 10 ** -4 / 2)
      assert.ok(Math.abs(pixel.day - 1) < 10 ** -5 / 2)
    })
  })

  it("comes back to the moon exactly after being dragged most of the way", () => {
    at(0.7)
    at(0.2)
    at(0).forEach((pixel, i) => {
      assert.ok(Math.abs(pixel.x - PAIRS[i].moon.x) < 10 ** -5 / 2)
      assert.ok(Math.abs(pixel.y - PAIRS[i].moon.y) < 10 ** -5 / 2)
    })
  })
})

describe("the swarm in between", () => {
  it("is mid-flight halfway: some home, some flying, some waiting", () => {
    const half = at(0.5)
    assert.ok(half.filter(pixel => pixel.day === 0).length > 0)
    assert.ok(half.filter(pixel => pixel.day > 0.02 && pixel.day < 0.98).length > 0)
    assert.ok(half.filter(pixel => pixel.day >= 0.98).length > 0)
  })

  it("has come as far as the knob, all told", () => {
    for (let k = 1; k < 20; k++) {
      const p = k / 20
      const pixels = at(p)
      const come = pixels.reduce((sum, pixel) => sum + pixel.day, 0) / pixels.length
      assert.ok(Math.abs(come - p) < 0.06)
    }
  })

  it("only ever comes further as the knob moves towards day", () => {
    let last = -1
    for (let k = 0; k <= 200; k++) {
      const pixels = at(k / 200)
      const come = pixels.reduce((sum, pixel) => sum + pixel.day, 0) / pixels.length
      assert.ok(come >= last - 0.02)
      last = come
    }
  })

  it("tumbles blocks in flight, off the square, and only those", () => {
    const half = at(0.5)
    const flying = half.filter(pixel => pixel.day > 0.2 && pixel.day < 0.8)
    assert.equal(flying.some(pixel => offSquare(pixel.spin) > 0.1), true)
    for (const pixel of half.filter(pixel => pixel.day === 0)) assert.equal(pixel.spin, 0)
  })
})

describe("tumbles", () => {
  it("turn each block at least a quarter and at most a few, always whole quarters", () => {
    for (const quarters of morph.tumbles) {
      assert.equal(Number.isInteger(quarters), true)
      assert.ok(quarters >= 1)
      assert.ok(quarters <= MOST_QUARTER_TURNS)
    }
    assert.ok(new Set(morph.tumbles).size > 1)
  })
})

describe("departures", () => {
  it("are one each, in order clockwise from straight down", () => {
    const departures = departureOrder(PAIRS)
    assert.deepEqual([...departures].sort((a, b) => a - b), PAIRS.map((_, i) => i))
    const byTurn = PAIRS.map((pair, i) => ({rank: departures[i], fromBottom: wrapAngle(pair.moon.angle - Math.PI / 2)}))
      .sort((a, b) => a.rank - b.rank)
    for (let i = 1; i < byTurn.length; i++) assert.ok(byTurn[i].fromBottom >= byTurn[i - 1].fromBottom)
  })

  it("set each pixel off no sooner than the one before it", () => {
    const steps = 600
    const leaves = new Array<number>(PAIRS.length).fill(Infinity)
    for (let k = 0; k <= steps; k++) {
      at(k / steps).forEach((pixel, i) => {
        const moved = Math.hypot(pixel.x - PAIRS[i].moon.x, pixel.y - PAIRS[i].moon.y) > 1e-4
        if (moved && leaves[i] === Infinity) leaves[i] = k
      })
    }
    const inOrder = PAIRS.map((_, i) => i).sort((a, b) => morph.departures[a] - morph.departures[b])
    for (let i = 1; i < inOrder.length; i++) assert.ok(leaves[inOrder[i]] >= leaves[inOrder[i - 1]])
  })
})

describe("the swirl", () => {
  it("carries each pixel the short way round to its partner plus whole turns", () => {
    const steps = 800
    const turned = new Array<number>(PAIRS.length).fill(0)
    let last = at(0)
    for (let k = 1; k <= steps; k++) {
      const now = at(k / steps)
      now.forEach((pixel, i) => {
        turned[i] += turnBetween(Math.atan2(last[i].y, last[i].x), Math.atan2(pixel.y, pixel.x))
      })
      last = now
    }
    PAIRS.forEach((pair, i) => {
      // A pixel that starts or lands on the centre has no direction there.
      if (pair.moon.radius === 0 || pair.sun.radius === 0) return
      const expected = turnBetween(pair.moon.angle, pair.sun.angle) + SWIRL_TURNS * 2 * Math.PI
      assert.ok(Math.abs(turned[i] - expected) < 10 ** -3 / 2)
    })
  })
})
