// Invariant: the theme switch's two pictures of blocks, read from the still face,
// become points round the grid's centre; when they have as many blocks, every
// block of one is paired with exactly one of the other by angle, so the swarm
// neither loses nor doubles a block on its way across; and at rest every block
// sits square on whole canvas pixels with a hairline between neighbours.
import assert from "node:assert/strict"
import {describe, it} from "node:test"
import {iconGrid, ICON_FILL, pairByAngle, pixelsOf, turnBetween, wrapAngle, type Cell, type Pixel} from "../../js/theme_switch/pixels.ts"

// A small, seeded source of numbers, so every run checks the same cases.
function numbers(seed: number) {
  let state = seed >>> 0
  return () => {
    state = (state * 1664525 + 1013904223) >>> 0
    return state / 2 ** 32
  }
}

function randomPicture(next: () => number, count: number): Pixel[] {
  return Array.from({length: count}, () => {
    const x = Math.round(next() * 8 - 4)
    const y = Math.round(next() * 8 - 4)
    return {x, y, angle: wrapAngle(Math.atan2(y, x)), radius: Math.hypot(x, y)}
  })
}

const key = (pixel: Pixel) => `${pixel.x},${pixel.y}`

/** The blocks of a picture drawn row by row, "#" for a block. */
const cellsOf = (rows: readonly string[]): Cell[] =>
  rows.flatMap((line, row) => [...line].flatMap((mark, col) => (mark === "#" ? [{col, row}] : [])))

// Two little pictures with as many blocks: a crescent and a sun.
const CRESCENT = [".##....", "##.....", "#......", "#......", "#.....#", "##...##", ".#####."]
const SUNBURST = ["#..#..#", ".......", "..###..", "#.###.#", "..###..", ".......", "#..#..#"]

function expectOneToOne(from: readonly Pixel[], to: readonly Pixel[], pairs: readonly {moon: Pixel; sun: Pixel}[]) {
  assert.equal(pairs.length, from.length)
  assert.deepEqual(new Set(pairs.map(pair => pair.moon)), new Set(from))
  assert.deepEqual(new Set(pairs.map(pair => pair.sun)), new Set(to))
}

describe("a picture's blocks", () => {
  it("become points round the grid's centre, right and down from it", () => {
    const pixels = pixelsOf([{col: 0, row: 0}, {col: 3, row: 3}, {col: 6, row: 3}, {col: 3, row: 6}], 7)
    assert.deepEqual(pixels.map(pixel => [pixel.x, pixel.y]), [[-3, -3], [0, 0], [3, 0], [0, 3]])
    assert.ok(Math.abs(pixels[2].angle - 0) < 10 ** -10 / 2)
    assert.ok(Math.abs(pixels[3].angle - Math.PI / 2) < 10 ** -10 / 2)
    assert.ok(Math.abs(pixels[0].radius - Math.hypot(3, 3)) < 10 ** -10 / 2)
  })

  it("sit half a cell from the centre on an even grid", () => {
    const [pixel] = pixelsOf([{col: 2, row: 1}], 4)
    assert.deepEqual([pixel.x, pixel.y], [0.5, -0.5])
  })

  it("of two pictures with as many blocks pair one to one", () => {
    const moon = pixelsOf(cellsOf(CRESCENT), 7)
    const sun = pixelsOf(cellsOf(SUNBURST), 7)
    assert.equal(moon.length, sun.length)
    const pairs = pairByAngle(moon, sun)
    assert.deepEqual(new Set(pairs.map(pair => key(pair.moon))), new Set(moon.map(key)))
    assert.deepEqual(new Set(pairs.map(pair => key(pair.sun))), new Set(sun.map(key)))
  })
})

describe("pairing by angle", () => {
  it("is one to one for any two pictures of the same size", () => {
    const next = numbers(7)
    for (let round = 0; round < 200; round++) {
      const count = 1 + Math.floor(next() * 40)
      const from = randomPicture(next, count)
      const to = randomPicture(next, count)
      expectOneToOne(from, to, pairByAngle(from, to))
    }
  })

  it("keeps the first picture's clockwise order", () => {
    const next = numbers(11)
    for (let round = 0; round < 100; round++) {
      const count = 2 + Math.floor(next() * 30)
      const pairs = pairByAngle(randomPicture(next, count), randomPicture(next, count))
      for (let i = 1; i < pairs.length; i++) assert.ok(pairs[i].moon.angle >= pairs[i - 1].moon.angle)
    }
  })

  it("turns no further, all told, than any other clockwise pairing", () => {
    const next = numbers(13)
    for (let round = 0; round < 100; round++) {
      const count = 1 + Math.floor(next() * 25)
      const from = randomPicture(next, count)
      const to = randomPicture(next, count)
      const total = (pairs: readonly {moon: Pixel; sun: Pixel}[]) =>
        pairs.reduce((sum, pair) => sum + Math.abs(turnBetween(pair.moon.angle, pair.sun.angle)), 0)
      const chosen = total(pairByAngle(from, to))
      const moons = [...from].sort((a, b) => a.angle - b.angle || a.radius - b.radius)
      const suns = [...to].sort((a, b) => a.angle - b.angle || a.radius - b.radius)
      for (let shift = 0; shift < count; shift++) {
        const other = moons.map((moon, i) => ({moon, sun: suns[(i + shift) % count]}))
        assert.ok(chosen <= total(other) + 1e-9)
      }
    }
  })

  it("pairs a picture with itself pixel for pixel", () => {
    const moon = pixelsOf(cellsOf(CRESCENT), 7)
    for (const pair of pairByAngle(moon, moon)) assert.equal(key(pair.sun), key(pair.moon))
  })

  it("refuses two pictures of different sizes", () => {
    const next = numbers(17)
    assert.throws(() => pairByAngle(randomPicture(next, 3), randomPicture(next, 4)))
  })
})

describe("turns between angles", () => {
  it("are the shortest way round, never more than half a turn", () => {
    const next = numbers(19)
    for (let round = 0; round < 500; round++) {
      const from = next() * 20 - 10
      const to = next() * 20 - 10
      const turn = turnBetween(from, to)
      assert.ok(Math.abs(turn) <= Math.PI + 1e-9)
      assert.ok(Math.abs(turnBetween(from + turn, to)) < 1e-9)
    }
  })
})

describe("the block grid", () => {
  it("sets every block's edges on whole pixels at rest, a hairline apart", () => {
    const next = numbers(41)
    for (let round = 0; round < 500; round++) {
      const grid = 5 + Math.floor(next() * 12)
      const side = 20 + next() * 120
      const centre = [next() * 300, next() * 300] as const
      const {x, y, cell, half} = iconGrid(centre, side, grid, 1)
      assert.equal(Number.isInteger(cell), true)
      const block = 2 * half * cell
      assert.ok(Math.abs(block - Math.round(block)) < 1e-9)
      if (cell >= 3) assert.ok(cell - block >= 1)
      for (const offset of [(grid - 1) / 2, -(grid - 1) / 2, ((grid - 1) / 2) % 1]) {
        for (const left of [x + offset * cell - block / 2, y + offset * cell - block / 2]) {
          assert.ok(Math.abs(left - Math.round(left)) < 1e-6)
        }
      }
      // Never far from the glass's own centre, and the picture spans about the share it should.
      assert.ok(Math.abs(x - centre[0]) <= 0.5 + 1e-9)
      assert.ok(Math.abs(y - centre[1]) <= 0.5 + 1e-9)
      assert.ok(Math.abs(cell * grid - ICON_FILL * side) <= grid / 2 + 1e-9)
    }
  })

  it("follows the glass's own centre in flight and moves smoothly to rest", () => {
    const centre = [101.37, 48.81] as const
    const flying = iconGrid(centre, 60, 13, 0)
    assert.deepEqual([flying.x, flying.y], [centre[0], centre[1]])
    let last = flying.x
    for (let k = 1; k <= 20; k++) {
      const {x} = iconGrid(centre, 60, 13, k / 20)
      assert.ok(Math.abs(x - last) <= 0.5 / 20 + 1e-9)
      last = x
    }
  })
})
