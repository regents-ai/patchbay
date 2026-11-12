// Invariant: dragging the theme switch's knob moves it with the finger and
// never past either end; let go, it settles on the nearer side, day from
// halfway; a press only becomes a drag once it has moved far enough sideways
// for the kind of pointer; and the light strip sits below the knob at night,
// above it by day, passing round the side it trails.
import assert from "node:assert/strict"
import {describe, it} from "node:test"
import {dragStart, draggedPosition, isDrag, settleSide, sideOf, stripAngle, themeOf} from "../../js/theme_switch/knob.ts"

function numbers(seed: number) {
  let state = seed >>> 0
  return () => {
    state = (state * 1664525 + 1013904223) >>> 0
    return state / 2 ** 32
  }
}

describe("a dragged knob", () => {
  it("stays between night and day however far the finger goes", () => {
    const next = numbers(3)
    for (let round = 0; round < 1000; round++) {
      const p = draggedPosition(next(), (next() - 0.5) * 400, next() * 60)
      assert.ok(p >= 0)
      assert.ok(p <= 1)
    }
  })

  it("follows the finger: further right is never further left", () => {
    const next = numbers(5)
    for (let round = 0; round < 300; round++) {
      const start = next()
      const travel = 1 + next() * 40
      const dx = (next() - 0.5) * 100
      assert.ok(draggedPosition(start, dx + next() * 10, travel) >= draggedPosition(start, dx, travel))
    }
  })

  it("crosses the whole track when the finger crosses the knob's travel", () => {
    assert.equal(draggedPosition(0, 22, 22), 1)
    assert.equal(draggedPosition(1, -22, 22), 0)
    assert.ok(Math.abs(draggedPosition(0, 11, 22) - 0.5) < 10 ** -10 / 2)
    assert.equal(draggedPosition(0.3, 0, 22), 0.3)
  })

  it("stays put on a track with no room to travel", () => {
    assert.equal(draggedPosition(0.4, 30, 0), 0.4)
    assert.equal(draggedPosition(0.4, 30, -5), 0.4)
    assert.equal(draggedPosition(0.4, 30, Number.NaN), 0.4)
  })
})

describe("a released knob", () => {
  it("settles on the nearer side, day from halfway", () => {
    assert.equal(settleSide(0), 0)
    assert.equal(settleSide(0.4999), 0)
    assert.equal(settleSide(0.5), 1)
    assert.equal(settleSide(1), 1)
    const next = numbers(9)
    for (let round = 0; round < 500; round++) {
      const p = next()
      assert.ok(Math.abs(p - settleSide(p)) <= 0.5)
    }
  })

  it("names night dark and day light, both ways", () => {
    assert.equal(themeOf(sideOf("dark")), "dark")
    assert.equal(themeOf(sideOf("light")), "light")
    assert.equal(sideOf("dark"), 0)
    assert.equal(sideOf("light"), 1)
  })
})

describe("a press", () => {
  it("becomes a drag once it has gone far enough sideways for its pointer", () => {
    for (const [type, distance] of [["mouse", 3], ["pen", 4], ["touch", 6]] as const) {
      assert.equal(dragStart(type), distance)
      assert.equal(isDrag(distance - 0.5, type), false)
      assert.equal(isDrag(distance, type), true)
      assert.equal(isDrag(-distance, type), true)
    }
  })

  it("treats a pointer it does not know as a finger", () => {
    assert.equal(dragStart(""), dragStart("touch"))
    assert.equal(dragStart("stylus-of-the-future"), dragStart("touch"))
  })
})

describe("the light strip", () => {
  it("sits below at night, beside the trailing side halfway and above by day", () => {
    const down = (angle: number) => [Math.cos(angle), Math.sin(angle)]
    const [nightX, nightY] = down(stripAngle(0))
    assert.ok(Math.abs(nightX - 0) < 10 ** -10 / 2)
    assert.ok(Math.abs(nightY - 1) < 10 ** -10 / 2)
    const [halfX, halfY] = down(stripAngle(0.5))
    assert.ok(Math.abs(halfX - -1) < 10 ** -10 / 2)
    assert.ok(Math.abs(halfY - 0) < 10 ** -10 / 2)
    const [dayX, dayY] = down(stripAngle(1))
    assert.ok(Math.abs(dayX - 0) < 10 ** -10 / 2)
    assert.ok(Math.abs(dayY - -1) < 10 ** -10 / 2)
  })

  it("goes round one way only and stops at either end", () => {
    let last = stripAngle(0)
    for (let k = 1; k <= 100; k++) {
      const angle = stripAngle(k / 100)
      assert.ok(angle > last)
      last = angle
    }
    assert.equal(stripAngle(-1), stripAngle(0))
    assert.equal(stripAngle(2), stripAngle(1))
  })
})
