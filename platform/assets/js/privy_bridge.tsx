import {createElement, useEffect} from "react"
import type {ComponentProps} from "react"
import {createRoot} from "react-dom/client"
import {PrivyProvider, getIdentityToken, useActiveWallet, useFiatOnramp, useLogin, usePrivy, useWallets} from "@privy-io/react-auth"
import type {ConnectedWallet, PrivyErrorCode} from "@privy-io/react-auth"
import type {Root} from "react-dom/client"
import {createProfileClient} from "../vendor/regent_identity/profile_client.mjs"
import type {ProfileAction} from "../vendor/regent_identity/profile_client.mjs"
import {NETWORK_CAIP2, USDC_CONTRACT} from "./webmcp/payment_readiness.ts"
import {hasWallet, providerConfig} from "./privy/provider.ts"
import type {SelectedWallet} from "./wallet_actions/send_step.ts"

// This module carries a whole wallet SDK, so it is a bundle of its own that the
// page fetches only when somebody asks to sign in. Everything it does is driven
// by a click; it never reconciles anything on its own, because a Privy state
// that is still hydrating is unknown, not signed out.

const CONTAINER_ID = "pb-privy-bridge"
const READY_TIMEOUT_MS = 20000
const TOKEN_TIMEOUT_MS = 15000
// Privy's own code for a person who closed the window instead of signing in.
const CLOSED_BY_USER = "exited_auth_flow"

// What Privy's hooks currently say, as the Bridge component publishes it.
type BridgeState = {
  ready: boolean
  authenticated: boolean
  user: ReturnType<typeof usePrivy>["user"]
  getAccessToken: ReturnType<typeof usePrivy>["getAccessToken"]
  logout: ReturnType<typeof usePrivy>["logout"]
  login: ReturnType<typeof useLogin>["login"]
  wallets: ConnectedWallet[]
  walletsReady: boolean
  activeWallet: ReturnType<typeof useActiveWallet>["wallet"]
  fund: ReturnType<typeof useFiatOnramp>["fund"]
}

type LoginOutcome = {ok: true} | {ok: false, code: PrivyErrorCode}

type Refusal = {ok: false, reason: string}

let mounted: {container: HTMLDivElement, root: Root} | null = null
let current: BridgeState | null = null
let settleLogin: ((outcome: LoginOutcome) => void) | null = null
let identityGeneration = 0
let mountedAppId: string | null = null
const waiters = new Set<(state: BridgeState) => void>()

function publish(state: BridgeState) {
  const changed = current?.user?.id !== state.user?.id || current?.authenticated !== state.authenticated
  current = state
  if (changed) identityGeneration += 1
  for (const waiter of Array.from(waiters)) waiter(state)
}

function finishLogin(outcome: LoginOutcome) {
  const settle = settleLogin
  settleLogin = null
  if (settle) settle(outcome)
}

// A component with nothing to draw: it exists so Privy's hooks can run, and
// publishes what they currently say to the plain functions below.
function Bridge() {
  const privy = usePrivy()
  const {wallets, ready: walletsReady} = useWallets()
  const {wallet: activeWallet} = useActiveWallet()
  const {fund} = useFiatOnramp()
  const {login} = useLogin({
    onComplete: () => finishLogin({ok: true}),
    onError: code => finishLogin({ok: false, code}),
  })

  useEffect(() => {
    publish({
      ready: privy.ready,
      authenticated: privy.authenticated,
      user: privy.user,
      getAccessToken: privy.getAccessToken,
      logout: privy.logout,
      login,
      wallets,
      walletsReady,
      activeWallet,
      fund,
    })
  })

  return null
}

type ProfileProof = {accessToken: string; identityToken: string; subject: string; isCurrent: () => boolean}

// One change to the shared profile belongs to the person signed in when it was
// opened, at the press of Save: a proof for anyone else is never handed on, so a
// switch of account before or part way through it sends nothing. As in ash-template.
export function oneSignIn(
  subject: string | null,
  acquireProof: () => Promise<ProfileProof | null>,
): () => Promise<ProfileProof | null> {
  return async () => {
    const proof = await acquireProof()
    return proof && proof.subject === subject ? proof : null
  }
}

// One change to the shared profile, read and saved with this sign-in's own proof,
// which is never handed to the page. It opens once Privy is ready and belongs to
// whoever is signed in then, so all of its calls belong to one person. It returns
// profile data, never credentials, and never opens login or a product session.
export async function openProfile(appId: string): Promise<ProfileAction> {
  start(appId)
  const opened = await waitFor(one => one.ready, 10_000)
  return createProfileClient({
    acquireProof: oneSignIn(opened.authenticated ? opened.user?.id ?? null : null, async () => {
      const state = current
      if (!state?.ready || !state.authenticated || !state.user?.id) return null
      const generation = identityGeneration
      const subject = state.user.id
      const identityToken = await getIdentityToken()
      const accessToken = await state.getAccessToken()
      const isCurrent = () => (current?.authenticated && current.user?.id === subject && identityGeneration === generation) as boolean
      return {accessToken: accessToken as string, identityToken: identityToken as string, subject, isCurrent}
    }),
  })
}

function start(appId: string) {
  if (mounted) {
    if (mountedAppId !== appId) throw new Error("privy_application_changed")
    return
  }
  mountedAppId = appId

  const container = document.createElement("div")
  container.id = CONTAINER_ID
  container.hidden = true
  document.body.appendChild(container)

  const root = createRoot(container)
  root.render(
    createElement(
      PrivyProvider,
      // Its children are the next argument, which React hands it as props.children.
      {appId, config: providerConfig} as ComponentProps<typeof PrivyProvider>,
      createElement(Bridge),
    ),
  )

  mounted = {container, root}
}

function waitFor(matches: (state: BridgeState) => boolean, timeoutMs: number): Promise<BridgeState> {
  if (current && matches(current)) return Promise.resolve(current)

  return new Promise((resolve, reject) => {
    const waiter = (state: BridgeState) => {
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
 * Nothing is sent anywhere from here; the caller posts the pair, and only once
 * the person's Privy account links an Ethereum wallet. A person who closes the
 * window, an account whose wallet Privy has not made (`no_wallet`), and a Privy
 * application that has not been told to issue identity tokens are each reported
 * rather than treated as a failure to sign in for some unnamed reason.
 */
export async function signIn(appId: string): Promise<{ok: true, access: string, identity: string} | Refusal> {
  start(appId)

  let state
  try {
    state = await waitFor(one => one.ready, READY_TIMEOUT_MS)
  } catch {
    return {ok: false, reason: "unready"}
  }

  if (!state.authenticated) {
    const outcome = await new Promise<LoginOutcome>(resolve => {
      settleLogin = resolve
      state.login()
    })

    if (!outcome.ok) {
      return {ok: false, reason: outcome.code === CLOSED_BY_USER ? "closed" : "refused"}
    }
  }

  // Nothing is handed over until the person has a wallet. Privy's window closes
  // once it has made the wallet of someone who signed in with email or Google;
  // a Privy sign-in this browser already held may still be making it.
  let withWallet
  try {
    withWallet = await waitFor(one => one.authenticated && hasWallet(one.user), TOKEN_TIMEOUT_MS)
  } catch {
    return {ok: false, reason: "no_wallet"}
  }

  // The evidence is asked for first and the session proof second, so the proof
  // is never older than the evidence it is offered with. As in ash-template.
  try {
    const identity = await getIdentityToken()
    const access = await withWallet.getAccessToken()

    if (!isToken(identity)) return {ok: false, reason: "no_identity_token"}
    if (!isToken(access)) return {ok: false, reason: "no_access_token"}

    return {ok: true, access, identity}
  } catch {
    return {ok: false, reason: "no_identity_token"}
  }
}

/**
 * Ends the Privy session behind an already-ended Patchbay one. Best effort:
 * the local session is already gone by the time this runs, so a failure here
 * changes nothing the page shows.
 */
export async function signOut(appId: string): Promise<void> {
  start(appId)

  const state = await waitFor(one => one.ready, READY_TIMEOUT_MS)
  if (state.authenticated) await state.logout()
}

/**
 * Privy's active wallet, when it is an Ethereum wallet still connected in this
 * browser: its address and the provider a payment is signed through. With none
 * open (`wallet_unavailable`), nothing opens and nothing is signed; the page
 * asks the person to open one of their wallets. One whose provider does not
 * answer is `wallet_unanswered`. The server decides whether this wallet may pay
 * for the account.
 */
export async function activeWallet(appId: string): Promise<{ok: true, wallet: SelectedWallet} | Refusal> {
  start(appId)

  let state
  try {
    state = await waitFor(one => one.ready && one.walletsReady, READY_TIMEOUT_MS)
  } catch {
    return {ok: false, reason: "unready"}
  }

  if (!state.authenticated) return {ok: false, reason: "signed_out"}

  const active = sendingWallet(state)
  if (!active) return {ok: false, reason: "wallet_unavailable"}

  try {
    const provider = await active.getEthereumProvider()
    return {ok: true, wallet: {address: active.address.toLowerCase(), provider}}
  } catch {
    return {ok: false, reason: "wallet_unanswered"}
  }
}

/**
 * The address of Privy's active wallet, lowercased, read without opening
 * anything: null when Privy holds no sign-in or no active wallet here.
 */
export async function activeAddress(appId: string): Promise<string | null> {
  start(appId)

  let state
  try {
    state = await waitFor(one => one.ready && one.walletsReady, READY_TIMEOUT_MS)
  } catch {
    return null
  }

  const active = state.authenticated ? sendingWallet(state) : null
  return active ? active.address.toLowerCase() : null
}

/**
 * Opens Privy's card top-up for the wallet this browser signed in with: the
 * person buys USDC on Base by card from one of Privy's card partners, and it
 * is delivered to that wallet. Patchbay sees no card details and moves no
 * money; the wallet then pays Patchbay the usual way.
 */
export async function addFundsByCard(appId: string): Promise<{ok: true, status: "submitted" | "confirmed"} | Refusal> {
  start(appId)

  let state
  try {
    state = await waitFor(one => one.ready, READY_TIMEOUT_MS)
  } catch {
    return {ok: false, reason: "unready"}
  }

  const address = state.authenticated ? state.user?.wallet?.address : null
  if (!address) return {ok: false, reason: "no_wallet"}

  try {
    const {status} = await state.fund({
      source: {assets: ["usd"], defaultAsset: "usd"},
      destination: {asset: USDC_CONTRACT, chain: NETWORK_CAIP2, address},
    })
    return {ok: true, status}
  } catch {
    return {ok: false, reason: "unfinished"}
  }
}

// An Ethereum wallet Privy has selected and still holds connected. A Solana
// selection, or one the wallet app has dropped, is no wallet rather than a
// reason to pick another. Privy names no wallet after a sign-in that skipped
// its window, or in a new tab: the signed-in wallet then sends as this browser
// has it connected, when exactly one connected wallet is linked to the account.
function sendingWallet({activeWallet: active, wallets, user}: BridgeState): ConnectedWallet | null {
  if (active) {
    if (active.type !== "ethereum") return null
    return wallets.some(one => sameAddress(one.address, active.address)) ? active : null
  }
  const linked = (user?.linkedAccounts ?? []).flatMap(account =>
    account.type === "wallet" && account.chainType === "ethereum" ? [account.address] : [],
  )
  const signedIn = wallets.filter(one => linked.some(address => sameAddress(address, one.address)))
  return signedIn.length === 1 ? signedIn[0] : null
}

function sameAddress(left: unknown, right: unknown): boolean {
  return typeof left === "string" && typeof right === "string" && left.toLowerCase() === right.toLowerCase()
}

function isToken(value: unknown): value is string {
  return typeof value === "string" && value.trim() !== ""
}
