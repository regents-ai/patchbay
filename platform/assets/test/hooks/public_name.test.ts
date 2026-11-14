// Invariant: Save on the Account page's Public Display Name writes the name to
// the profile it just read, with the page's own sign-in, and never writes after
// a read that failed. Every step of one save belongs to one person: a switch of
// account part way through writes nothing, and a save waiting its turn belongs to
// the person signed in at its press. Two quick presses keep the name pressed
// last, and a save that fails outright never leaves the form busy. As
// ash-template's public_name.test.ts.
import assert from "node:assert/strict"
import {afterEach, test} from "node:test"

import {PublicName} from "../../js/hooks/public_name.ts"

const page = {document: globalThis.document, fetch: globalThis.fetch}

afterEach(() => {
  globalThis.document = page.document
  globalThis.fetch = page.fetch
})

// The site as RegentIdentity.HTTP serves it behind PatchbayWeb.Plugs.ProfileOwner:
// each request acts for the person the browser's session cookie names, and a
// change needs that session's forms token. A sign-in renews the session and its
// token, and makes the person's profile when they have none.
function site(first: string | null) {
  let session = first ? {person: first, token: `token-${first}`} : null
  const profiles = new Map<string, {profile_id: string; display_name: string | null}>()
  const writes: string[] = []
  const signedOut = () => Response.json({error: {code: "authentication_required"}}, {status: 401})
  const fetch = (async (path: string, init: RequestInit) => {
    const headers = init.headers as Record<string, string>
    const caller = session
    if (!caller) return signedOut()
    const mine = profiles.get(caller.person)
    if (init.method === "GET") {
      return mine ? Response.json({profile: mine}) : Response.json({error: {code: "profile_not_created"}}, {status: 404})
    }
    if (headers["x-csrf-token"] !== caller.token) return signedOut()
    const expected = headers["x-regent-profile-id"]
    if (!mine || (expected && expected !== mine.profile_id)) {
      return Response.json({error: {code: "invalid_profile_update"}}, {status: 422})
    }
    writes.push(`${init.method} ${path} ${caller.person}`)
    mine.display_name = JSON.parse(String(init.body)).display_name
    return Response.json({profile: mine})
  }) as typeof globalThis.fetch
  const signIn = (person: string) => {
    session = {person, token: `token-${person}`}
    if (!profiles.has(person)) profiles.set(person, {profile_id: `profile-${person}`, display_name: null})
  }
  if (first) signIn(first)
  // The page's forms token: the one it was served with, until the page adopts a new one.
  let pageToken = session?.token ?? ""
  const adoptToken = () => { pageToken = session?.token ?? "" }
  globalThis.document = {
    querySelector: (selector: string) => selector === "meta[name='csrf-token']" ? {content: pageToken} : null,
  } as unknown as Document
  return {fetch, profiles, writes, signIn, adoptToken}
}

// The form as the page holds it: just what the design system's mountProfile reads
// and writes, mounted by the page's own hook.
function accountPage(fetch: typeof globalThis.fetch) {
  globalThis.fetch = fetch
  let submit: ((event: {preventDefault(): void}) => Promise<void>) | null = null
  const attributes = new Map<string, string>()
  const status = {textContent: ""}
  const name = {value: ""}
  const element = {
    elements: {namedItem: () => name},
    addEventListener: (_: string, listener: typeof submit) => { submit = listener },
    setAttribute: (key: string, value: string) => attributes.set(key, value),
    removeAttribute: (key: string) => attributes.delete(key),
  }
  const root = {querySelector: (selector: string) => selector === "[data-profile-form]" ? element : status}
  const saved: string[] = []
  PublicName.mounted!.call({el: root, pushEvent: (event: string) => saved.push(event)})
  const press = (typed: string) => { name.value = typed; return submit!({preventDefault() {}}) }
  return {attributes, status, name, press, saved}
}

test("a save writes the name to the profile it read, with the page's forms token", async () => {
  const service = site("did:a")
  const form = accountPage(service.fetch)

  await form.press("Ada")
  assert.equal(service.profiles.get("did:a")?.display_name, "Ada")
  assert.deepEqual(service.writes, ["PATCH /api/v1/profile did:a"])
  assert.equal(form.name.value, "Ada")
  assert.deepEqual(form.saved, ["public_name_saved"])
})

test("nothing is written without a sign-in", async () => {
  const service = site(null)
  const form = accountPage(service.fetch)

  await form.press("Ada")
  assert.deepEqual(service.writes, [])
  assert.equal(form.attributes.has("aria-busy"), false)
  assert.notEqual(form.status.textContent, "")
  assert.deepEqual(form.saved, [])
})

test("a switch of account after the first read saves nothing to either account", async () => {
  const service = site("did:a")
  // Another tab signs in as someone else once this save has read the profile.
  const switching: typeof globalThis.fetch = async (input, init) => {
    const answer = await service.fetch(input, init)
    if (init?.method === "GET") { service.signIn("did:b"); service.adoptToken() }
    return answer
  }
  const form = accountPage(switching)

  await form.press("Ada")
  assert.deepEqual(service.writes, [])
  assert.equal(service.profiles.get("did:a")?.display_name, null)
  assert.equal(service.profiles.get("did:b")?.display_name, null)
  assert.deepEqual(form.saved, [])
})

test("a save pressed before a switch of account, still waiting its turn, saves to neither account", async () => {
  const service = site("did:a")
  // The first save's change reaches the server, then the person switches account,
  // and the page adopts the new session's token, while the second save waits.
  const switchDuringFirstWrite: typeof globalThis.fetch = async (input, init) => {
    const answer = await service.fetch(input, init)
    if (init?.method === "PATCH") { service.signIn("did:b"); service.adoptToken() }
    return answer
  }
  const form = accountPage(switchDuringFirstWrite)

  await Promise.all([form.press("Ada"), form.press("Grace")])
  assert.equal(service.profiles.get("did:a")?.display_name, "Ada")
  assert.equal(service.profiles.get("did:b")?.display_name, null)
  assert.deepEqual(service.writes, ["PATCH /api/v1/profile did:a"])
  // Only the save pressed last speaks for the form, and it saved nothing.
  assert.deepEqual(form.saved, [])
  assert.equal(form.attributes.has("aria-busy"), false)
})

test("a save that fails outright says so and leaves the form ready", async () => {
  site("did:a")
  const form = accountPage(async () => { throw new TypeError("network down") })

  await form.press("Ada")
  assert.equal(form.attributes.has("aria-busy"), false)
  assert.notEqual(form.status.textContent, "")
  assert.deepEqual(form.saved, [])
})

test("two quick saves keep the name pressed last, however slow the first is", async () => {
  const service = site("did:a")
  let firstRead = true
  const slowFirstRead: typeof globalThis.fetch = async (input, init) => {
    if (init?.method === "GET" && firstRead) {
      firstRead = false
      await new Promise(resolve => setTimeout(resolve, 20))
    }
    return service.fetch(input, init)
  }
  const form = accountPage(slowFirstRead)

  await Promise.all([form.press("Ada"), form.press("Grace")])
  assert.equal(service.profiles.get("did:a")?.display_name, "Grace")
  assert.equal(form.name.value, "Grace")
  assert.equal(form.attributes.has("aria-busy"), false)
  assert.deepEqual(form.saved, ["public_name_saved"])
})
