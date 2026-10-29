import {createElement, useEffect} from "react"
import type {ComponentProps} from "react"
import {createRoot} from "react-dom/client"
import {PrivyProvider, getIdentityToken, useActiveWallet, useFiatOnramp, useLogin, usePrivy, useWallets} from "@privy-io/react-auth"
import type {ConnectedWallet, PrivyErrorCode} from "@privy-io/react-auth"
import type {Root} from "react-dom/client"
import {createProfileClient} from "../vendor/regent_identity/profile_client.mjs"
import type {ProfileAction} from "../vendor/regent_identity/profile_client.mjs"
import {NETWORK_CAIP2, USDC_CONTRACT} from "./webmcp/payment_readiness.ts"
import {providerConfig} from "./privy/provider.ts"
import {handOver, stateWaiters} from "./privy/sign_in.ts"
import type {Proof, Refusal} from "./privy/sign_in.ts"
import {sendingWallet} from "./privy/wallet_choice.ts"
import type {SelectedWallet} from "./wallet_actions/send_step.ts"

// This module carries a whole wallet SDK, so it is a bundle of its own that the
// page fetches only when somebody asks to sign in. Everything it does is driven
// by a click; it never reconciles anything on its own, because a Privy state
// that is still hydrating is unknown, not signed out.

const CONTAINER_ID = "pb-privy-bridge"
const READY_TIMEOUT_MS = 20000
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

let mounted: {container: HTMLDivElement, root: Root} | null = null
const published = stateWaiters<BridgeState>()
let settleLogin: ((outcome: LoginOutcome) => void) | null = null
let identityGeneration = 0
let mountedAppId: string | null = null
const waitFor = published.waitFor

function publish(next: BridgeState) {
  const current = published.current()
  if (current?.user?.id !== next.user?.id || current?.authenticated !== next.authenticated) identityGeneration += 1
  published.publish(next)
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
      const signedIn = published.current()
      if (!signedIn?.ready || !signedIn.authenticated || !signedIn.user?.id) return null
      const generation = identityGeneration
      const subject = signedIn.user.id
      const identityToken = await getIdentityToken()
      const accessToken = await signedIn.getAccessToken()
      const isCurrent = () => {
        const now = published.current()
        return (now?.authenticated && now.user?.id === subject && identityGeneration === generation) as boolean
      }
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

/**
 * Signs in with Privy and hands back the pair of tokens the server verifies.
 *
 * Nothing is sent anywhere from here; the caller posts the pair, and only once
 * the person's Privy account links an Ethereum wallet. A person who closes the
 * window, an account whose wallet Privy has not made (`no_wallet`), and a Privy
 * application that has not been told to issue identity tokens are each reported
 * rather than treated as a failure to sign in for some unnamed reason.
 */
export async function signIn(appId: string): Promise<Proof | Refusal> {
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

  return handOver(waitFor, getIdentityToken)
}

/**
 * Finishes a Google or other redirect sign-in on the page Privy brought the
 * person back to (`?privy_oauth_code=`), which completes only once Privy runs
 * here. The window the person opened on the page before speaks for this page:
 * Privy completes it once it has handled the return and made the person's
 * wallet, then the pair is handed back as `signIn` hands it. As ash-template,
 * where a redirect return starts the bridge with its sign-in window open.
 */
export async function finishRedirectSignIn(appId: string): Promise<Proof | Refusal> {
  const completed = new Promise<LoginOutcome>(resolve => { settleLogin = resolve })
  start(appId)

  let timer: ReturnType<typeof setTimeout> | undefined
  const outcome = await Promise.race([
    completed,
    new Promise<null>(resolve => { timer = setTimeout(() => resolve(null), READY_TIMEOUT_MS) }),
  ])
  clearTimeout(timer)

  if (!outcome) return {ok: false, reason: "unready"}
  if (!outcome.ok) return {ok: false, reason: outcome.code === CLOSED_BY_USER ? "closed" : "refused"}

  return handOver(waitFor, getIdentityToken)
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
 * The wallet that sends for the signed-in account (`sendingWallet`): Privy's
 * active wallet when the account links it, else the account's own wallet this
 * tab holds connected. Its address and the provider a payment is signed through.
 * With none (`wallet_unavailable`), nothing opens and nothing is signed; the page
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

  const active = signedInWallet(state)
  if (!active) return {ok: false, reason: "wallet_unavailable"}

  try {
    const provider = await active.getEthereumProvider()
    return {ok: true, wallet: {address: active.address.toLowerCase(), provider}}
  } catch {
    return {ok: false, reason: "wallet_unanswered"}
  }
}

/**
 * The address of the wallet that sends for the signed-in account, lowercased,
 * read without opening anything: null when Privy holds no sign-in here or the
 * tab holds none of the account's wallets.
 */
export async function activeAddress(appId: string): Promise<string | null> {
  start(appId)

  let state
  try {
    state = await waitFor(one => one.ready && one.walletsReady, READY_TIMEOUT_MS)
  } catch {
    return null
  }

  const active = state.authenticated ? signedInWallet(state) : null
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

// Every wallet the account links as Patchbay verified it at sign-in
// (`data-account-wallets`), the same list the server lets pay, so the page never
// sends from a wallet the server would refuse, such as a Privy wallet made after
// this sign-in handed over.
function accountWallets(): string[] {
  const listed = document.querySelector<HTMLElement>("#pb-account")?.dataset.accountWallets ?? ""
  return listed.split(" ").filter(Boolean).map(address => address.toLowerCase())
}

// The account's main wallet the page was drawn for (`data-account-wallet`), which
// sends when this tab holds several of the account's wallets and Privy names none.
function accountWallet(): string | null {
  return document.querySelector<HTMLElement>("#pb-account")?.dataset.accountWallet?.toLowerCase() ?? null
}

function signedInWallet({activeWallet: active, wallets}: BridgeState): ConnectedWallet | null {
  return sendingWallet(active, wallets, accountWallets(), accountWallet())
}
