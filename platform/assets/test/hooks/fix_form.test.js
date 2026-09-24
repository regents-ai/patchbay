import assert from "node:assert/strict"
import {test} from "node:test"

import {fixArguments, fixOutcome} from "../../js/fix_form.js"

test("the form's fields become one assist request, with a tried tool as a believed call", () => {
  const made = fixArguments({
    goal: " Book the 9am table ", site_url: "https://bookings.example.com/app",
    expected_result: "A booking reference", sign_in: "", tool: "reserve_table", arguments: '{"party": 2}',
  })
  assert.equal(made.ok, true)
  assert.deepEqual(made.args, {
    goal: "Book the 9am table", site_url: "https://bookings.example.com/app",
    expected_result: "A booking reference", sign_in: "unknown",
    believed_calls: [{tool: "reserve_table", arguments: {party: 2}}],
  })
  assert.deepEqual(fixArguments({goal: "x", tool: "", arguments: "junk"}).args.believed_calls, [])
  assert.deepEqual(fixArguments({goal: "x", tool: "t", arguments: ""}).args.believed_calls, [{tool: "t", arguments: {}}])
})

test("arguments that are not a JSON object are refused in words", () => {
  for (const raw of ["junk", "[1]", "3", "null"]) {
    const made = fixArguments({goal: "x", tool: "t", arguments: raw})
    assert.equal(made.ok, false)
    assert.match(made.problem, /JSON object/)
  }
})

test("an applied payment or a fix already under way goes to the fix; anything else is said", () => {
  assert.deepEqual(fixOutcome({status: 200, body: {status: "applied"}, intent: {run_id: "abc"}}), {navigate: "/fixes/abc"})
  assert.deepEqual(fixOutcome({status: 409, body: {problem_code: "assist_running", run_id: "def"}}), {navigate: "/fixes/def"})
  assert.match(fixOutcome({status: 409, body: {status: "settlement_pending", error: "Wait."}, intent: {run_id: "abc"}}).problem, /Wait/)
  assert.match(fixOutcome({status: 202, body: {status: "settled"}, intent: {run_id: "abc"}}).problem, /not be charged again/)
  assert.match(fixOutcome({status: 402, body: {error: "Not enough USDC."}, intent: {run_id: "abc"}}).problem, /Not enough USDC/)
  assert.match(fixOutcome({status: 402, body: {}, intent: {}, unsigned: "closed"}).problem, /closed/)
  assert.match(fixOutcome({status: 0, body: null}).problem, /could not be paid/)
})
