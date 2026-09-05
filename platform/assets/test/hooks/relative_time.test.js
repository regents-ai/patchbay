import assert from "node:assert/strict"
import {test} from "node:test"

import {inWords} from "../../js/hooks/relative_time.js"

const NOW = Date.parse("2026-09-01T12:00:00Z")

function ago(seconds) {
  return new Date(NOW - seconds * 1000).toISOString()
}

test("anything under a minute old reads as just now", () => {
  assert.equal(inWords(ago(0), NOW), "just now")
  assert.equal(inWords(ago(59), NOW), "just now")
})

test("a moment still in the future reads as just now", () => {
  assert.equal(inWords(ago(-10), NOW), "just now")
})

test("counts in the largest whole unit that fits", () => {
  assert.equal(inWords(ago(60), NOW), "1 minute ago")
  assert.equal(inWords(ago(180), NOW), "3 minutes ago")
  assert.equal(inWords(ago(3_600), NOW), "1 hour ago")
  assert.equal(inWords(ago(7_200), NOW), "2 hours ago")
  assert.equal(inWords(ago(86_400), NOW), "1 day ago")
  assert.equal(inWords(ago(604_800), NOW), "1 week ago")
  assert.equal(inWords(ago(2_592_000), NOW), "1 month ago")
  assert.equal(inWords(ago(31_536_000), NOW), "1 year ago")
})

test("says nothing at all when the timestamp is unreadable", () => {
  assert.equal(inWords("not a timestamp", NOW), "")
  assert.equal(inWords(null, NOW), "")
})
