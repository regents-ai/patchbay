// Invariant: the blocks reach the shader sorted top to bottom, each exactly
// once, so a pixel that looks only at the blocks in its own band still finds
// every block that can cover it; each turn arrives as its cosine and sine, and
// a block is whole at rest and smaller in flight.
import assert from "node:assert/strict"
import {describe, it} from "node:test"
import {FLIGHT_SHRINK, packBlocks, PIXEL_SLOTS} from "../../js/theme_switch/shader.ts"

// x, y, turn and share of day for five blocks, in no order down the picture.
const BLOCKS = [
  [2, 3, 0, 0],
  [-1, -4, Math.PI / 2, 1],
  [0, 0.5, Math.PI / 4, 0.5],
  [3, -4, Math.PI, 0.25],
  [-2, 1, 0, 1],
]
const STRIDE = 4
const HALF = 0.4

function pack() {
  const place = new Float32Array(PIXEL_SLOTS * 4).fill(9)
  const look = new Float32Array(PIXEL_SLOTS * 4).fill(9)
  packBlocks(new Float32Array(BLOCKS.flat()), STRIDE, BLOCKS.length, HALF, place, look)
  const slot = (data: Float32Array, i: number) => [...data.subarray(i * 4, i * 4 + 4)]
  return {place, look, slot}
}

describe("the blocks as the shader reads them", () => {
  it("go top to bottom, each block once", () => {
    const {place, slot} = pack()
    const ys = BLOCKS.map((_, i) => slot(place, i)[1])
    assert.deepEqual(ys, [...ys].sort((a, b) => a - b))
    const sent = BLOCKS.map((_, i) => slot(place, i).slice(0, 2).join()).sort()
    assert.deepEqual(sent, BLOCKS.map(([x, y]) => `${x},${y}`).sort())
  })

  it("carry each turn as its cosine and sine, and each block's look beside it", () => {
    const {place, look, slot} = pack()
    BLOCKS.forEach((_, i) => {
      const [x, y, cos, sin] = slot(place, i)
      const [, day] = slot(look, i)
      const block = BLOCKS.find(([bx, by]) => bx === x && by === y)!
      assert.ok(Math.abs(cos - Math.cos(block[2])) < 10 ** -6 / 2)
      assert.ok(Math.abs(sin - Math.sin(block[2])) < 10 ** -6 / 2)
      assert.ok(Math.abs(day - block[3]) < 10 ** -6 / 2)
    })
  })

  it("keeps a block whole at rest and makes it smaller in flight", () => {
    const {look, slot} = pack()
    BLOCKS.forEach((_, i) => {
      const [half, day] = slot(look, i)
      if (day === 0 || day === 1) assert.ok(Math.abs(half - HALF) < 10 ** -6 / 2)
      else assert.ok(half < HALF)
      if (day === 0.5) assert.ok(Math.abs(half - HALF * (1 - FLIGHT_SHRINK)) < 10 ** -6 / 2)
    })
  })

  it("leaves the slots past the last block empty", () => {
    const {place, look} = pack()
    assert.equal([...place.subarray(BLOCKS.length * 4)].every(v => v === 0), true)
    assert.equal([...look.subarray(BLOCKS.length * 4)].every(v => v === 0), true)
  })
})
