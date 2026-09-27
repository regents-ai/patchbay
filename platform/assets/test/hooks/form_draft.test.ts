import assert from "node:assert/strict"
import {test} from "node:test"

import {keepDraft, restoreDraft} from "../../js/form_draft.ts"

const NAMES = ["thread[site]", "thread[thread_kind]", "thread[title]"]

function memory() {
  const kept = new Map<string, string>()
  return {
    getItem: (key: string) => kept.get(key) ?? null,
    setItem: (key: string, value: string) => kept.set(key, value),
    removeItem: (key: string) => kept.delete(key),
    kept,
  }
}

function form(values: Record<string, string>) {
  const elements: Record<string, {value: string; tagName: string}> = {}
  for (const [name, value] of Object.entries(values)) {
    elements[name] = {value, tagName: name.endsWith("kind]") ? "SELECT" : "INPUT"}
  }
  return {elements}
}

test("a draft kept before a sign-in comes back once, into the fresh page", () => {
  const storage = memory()
  keepDraft(form({"thread[site]": "shop.example", "thread[thread_kind]": "discussion", "thread[title]": "How?"}), storage, "k", NAMES)

  // The reloaded page: the site came from the address, the rest is empty.
  const fresh = form({"thread[site]": "tables.example", "thread[thread_kind]": "question", "thread[title]": ""})
  restoreDraft(fresh, storage, "k", NAMES)

  assert.equal(fresh.elements["thread[site]"].value, "tables.example")
  assert.equal(fresh.elements["thread[thread_kind]"].value, "discussion")
  assert.equal(fresh.elements["thread[title]"].value, "How?")
  assert.equal(storage.kept.size, 0)

  const again = form({"thread[site]": "", "thread[thread_kind]": "question", "thread[title]": ""})
  restoreDraft(again, storage, "k", NAMES)
  assert.equal(again.elements["thread[title]"].value, "")
})

test("no storage, or a broken one, leaves the form as it is", () => {
  const page = form({"thread[site]": "", "thread[thread_kind]": "question", "thread[title]": ""})
  keepDraft(page, null, "k", NAMES)
  restoreDraft(page, null, "k", NAMES)
  const broken = {getItem: () => "{not json", setItem: () => {}, removeItem: () => {}}
  restoreDraft(page, broken, "k", NAMES)
  assert.equal(page.elements["thread[title]"].value, "")
})
