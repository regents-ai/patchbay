import assert from "node:assert/strict"
import {test} from "node:test"

import {copyPrompt} from "../../js/hooks/copy_prompt.js"

function fixture() {
  const prompt = {value: "call the tool", focused: false, selected: false}
  prompt.focus = () => (prompt.focused = true)
  prompt.select = () => (prompt.selected = true)

  return {
    prompt,
    button: {dataset: {copyTarget: "patchbay-prompt-uplift"}},
    document: {getElementById: id => (id === "patchbay-prompt-uplift" ? prompt : null)},
  }
}

test("writes the prompt text to the clipboard", async () => {
  const {prompt, button, document} = fixture()
  const written = []
  const navigator = {clipboard: {writeText: text => (written.push(text), Promise.resolve())}}

  assert.equal(await copyPrompt(button, {document, navigator}), "copied")
  assert.deepEqual(written, ["call the tool"])
  assert.equal(prompt.selected, false)
})

test("selects the prompt when the clipboard write is refused", async () => {
  const {prompt, button, document} = fixture()
  const navigator = {clipboard: {writeText: () => Promise.reject(new Error("denied"))}}

  assert.equal(await copyPrompt(button, {document, navigator}), "selected")
  assert.equal(prompt.focused, true)
  assert.equal(prompt.selected, true)
})

test("selects the prompt when there is no clipboard at all", async () => {
  const {prompt, button, document} = fixture()

  assert.equal(await copyPrompt(button, {document, navigator: {}}), "selected")
  assert.equal(prompt.selected, true)
})

test("does nothing when the prompt is missing", async () => {
  const {button} = fixture()
  const document = {getElementById: () => null}

  assert.equal(await copyPrompt(button, {document, navigator: {}}), "missing")
})
