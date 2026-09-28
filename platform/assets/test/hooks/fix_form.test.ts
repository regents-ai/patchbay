import assert from "node:assert/strict"
import {test} from "node:test"

import {fixArguments, fixOutcome} from "../../js/fix_form.ts"

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
  assert.deepEqual(fixOutcome({status: 409, body: {problem_code: "assist_running", run_id: "def"}}), {navigate: "/fixes/def"})
  assert.match(fixOutcome({status: 409, body: {status: "settlement_pending", error: "Wait."}, intent: {run_id: "abc"}}).problem!, /Wait/)
  assert.match(fixOutcome({status: 202, body: {status: "settled"}, intent: {run_id: "abc"}}).problem!, /not be charged again/)
  assert.match(fixOutcome({status: 402, body: {error: "Not enough USDC."}, intent: {run_id: "abc"}}).problem!, /Not enough USDC/)
  assert.match(fixOutcome({status: 402, body: {}, intent: {}, unsigned: "closed"}).problem!, /closed/)
  assert.match(fixOutcome({status: 0, body: null}).problem!, /could not be paid/)
})
