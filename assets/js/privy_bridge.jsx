import {createElement, useEffect} from "react"
import {createRoot} from "react-dom/client"
import {PrivyProvider, useIdentityToken, useLogin, usePrivy} from "@privy-io/react-auth"

// This module carries a whole wallet SDK, so it is a bundle of its own that the
// page fetches only when somebody asks to sign in. Everything it does is driven
// by a click; it never reconciles anything on its own, because a Privy state
// that is still hydrating is unknown, not signed out.

const CONTAINER_ID = "pb-privy-bridge"
const READY_TIMEOUT_MS = 20000
const TOKEN_TIMEOUT_MS = 15000
// Privy's own code for a person who closed the window instead of signing in.
const CLOSED_BY_USER = "exited_auth_flow"

let mounted = null
let current = null
let settleLogin = null
const waiters = new Set()

function publish(state) {
  current = state
  for (const waiter of Array.from(waiters)) waiter(state)
}

function finishLogin(outcome) {
  const settle = settleLogin
  settleLogin = null
  if (settle) settle(outcome)
}

// A component with nothing to draw: it exists so Privy's hooks can run, and
// publishes what they currently say to the plain functions below.
function Bridge() {
  const privy = usePrivy()
  const {identityToken} = useIdentityToken()
  const {login} = useLogin({
    onComplete: () => finishLogin({ok: true}),
    onError: code => finishLogin({ok: false, code}),
  })

  useEffect(() => {
    publish({
      ready: privy.ready,
      authenticated: privy.authenticated,
      getAccessToken: privy.getAccessToken,
      logout: privy.logout,
      identityToken,
      login,
    })
  })

  return null
}

function start(appId) {
  if (mounted) return

  const container = document.createElement("div")
  container.id = CONTAINER_ID
  container.hidden = true
  document.body.appendChild(container)

  const root = createRoot(container)
  root.render(
    createElement(
      PrivyProvider,
      {appId, config: {loginMethods: ["wallet"]}},
      createElement(Bridge),
    ),
  )

  mounted = {container, root}
}

function waitFor(matches, timeoutMs) {
  if (current && matches(current)) return Promise.resolve(current)

  return new Promise((resolve, reject) => {
    const waiter = state => {
      if (!matches(state)) return
      clearTimeout(timer)
      waiters.delete(waiter)
      resolve(state)
    }
    const timer = setTimeout(() => {
      waiters.delete(waiter)
      reject(new Error("privy_timeout"))
    }, timeoutMs)

    waiters.add(waiter)
  })
}

/**
 * Signs in with Privy and hands back the pair of tokens the server verifies.
 *
 * Nothing is sent anywhere from here; the caller posts the pair. A person who
 * closes the window, and a Privy application that has not been told to issue
 * identity tokens, are both reported rather than treated as a failure to sign
 * in for some unnamed reason.
 *
 * @param {string} appId
 * @returns {Promise<{ok: true, access: string, identity: string} | {ok: false, reason: string}>}
 */
export async function signIn(appId) {
  start(appId)

  let state
  try {
    state = await waitFor(one => one.ready, READY_TIMEOUT_MS)
  } catch {
    return {ok: false, reason: "unready"}
  }

  if (!state.authenticated) {
    const outcome = await new Promise(resolve => {
      settleLogin = resolve
      state.login()
    })

    if (!outcome.ok) {
      return {ok: false, reason: outcome.code === CLOSED_BY_USER ? "closed" : "refused"}
    }
  }

  try {
    const authenticated = await waitFor(one => one.authenticated, TOKEN_TIMEOUT_MS)
    const access = await authenticated.getAccessToken()
    const withIdentity = await waitFor(one => isToken(one.identityToken), TOKEN_TIMEOUT_MS)

    if (!isToken(access)) return {ok: false, reason: "no_access_token"}

    return {ok: true, access, identity: withIdentity.identityToken}
  } catch {
    return {ok: false, reason: "no_identity_token"}
  }
}

/**
 * Ends the Privy session behind an already-ended Patchbay one. Best effort:
 * the local session is already gone by the time this runs, so a failure here
 * changes nothing the page shows.
 *
 * @param {string} appId
 */
export async function signOut(appId) {
  start(appId)

  const state = await waitFor(one => one.ready, READY_TIMEOUT_MS)
  if (state.authenticated) await state.logout()
}

function isToken(value) {
  return typeof value === "string" && value.trim() !== ""
}
