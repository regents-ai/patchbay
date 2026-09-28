import assert from "node:assert/strict"
import {test} from "node:test"

import {fixArguments, fixOutcome} from "../../js/hero_form.ts"

test("the form's two texts and the picked tools become one assist request", () => {
  assert.deepEqual(
    fixArguments({goal: " Book the 9am table ", site_url: " bookings.example.com/app "}, ["reserve_table", "list_tables"]),
    {
      goal: "Book the 9am table", site_url: "bookings.example.com/app", sign_in: "unknown",
      believed_calls: [{tool: "reserve_table"}, {tool: "list_tables"}],
    },
  )
  assert.deepEqual(fixArguments({goal: "x", site_url: "y"}, []).believed_calls, [])
})

test("an applied payment or a fix already under way goes to the fix; anything else is said", () => {
  assert.deepEqual(fixOutcome({status: 200, body: {status: "applied"}, intent: {run_id: "abc"}}), {navigate: "/fixes/abc"})
  const running = {code: "assist_running", message: "A fix is already under way.", hint: "Read it at assist_url.", run_id: "def"}
  assert.deepEqual(fixOutcome({status: 409, body: {error: running}}), {navigate: "/fixes/def"})
  const pending = {code: "settlement_pending", message: "Wait.", hint: "Do not pay again.", status: "settlement_pending"}
  assert.match(fixOutcome({status: 409, body: {error: pending}, intent: {run_id: "abc"}}).problem!, /Wait/)
  assert.match(fixOutcome({status: 202, body: {status: "settled"}, intent: {run_id: "abc"}}).problem!, /not be charged again/)
  const short = {code: "invalid", message: "Not enough USDC.", hint: "Correct the fields in details, then send it again.", details: ["Not enough USDC."]}
  assert.match(fixOutcome({status: 422, body: {error: short}, intent: {run_id: "abc"}}).problem!, /Not enough USDC/)
  assert.match(fixOutcome({status: 402, body: {}, intent: {}, unsigned: "closed"}).problem!, /closed/)
  assert.match(fixOutcome({status: 0, body: null}).problem!, /could not be paid/)
})
