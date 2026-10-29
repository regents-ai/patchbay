import type {User} from "@privy-io/react-auth"
import {hasWallet} from "./provider.ts"

export type Proof = {ok: true; access: string; identity: string}
export type Refusal = {ok: false; reason: string}

export const TOKEN_TIMEOUT_MS = 15_000

/** What a sign-in reads of Privy's state. */
export type SignInState = {
  authenticated: boolean
  user: Pick<User, "linkedAccounts"> | null
  getAccessToken: () => Promise<string | null>
}

/**
 * The latest state Privy's hooks published, and waits on it: a wait ends with
 * the first state that matches, or rejects with `privy_timeout` after
 * `timeoutMs`.
 */
export function stateWaiters<S>() {
  let current: S | null = null
  const waiters = new Set<(state: S) => void>()

  return {
    current: () => current,
    publish(state: S) {
      current = state
      for (const waiter of Array.from(waiters)) waiter(state)
    },
    waitFor(matches: (state: S) => boolean, timeoutMs: number): Promise<S> {
      if (current && matches(current)) return Promise.resolve(current)

      return new Promise((resolve, reject) => {
        const waiter = (state: S) => {
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
    },
  }
}

/**
 * Privy's two tokens for the signed-in person, once their account links an
 * Ethereum wallet. Privy's window closes once it has made the wallet of someone
 * who signed in with email or Google, and a Privy sign-in this browser already
 * held may still be making it; Patchbay refuses a sign-in with no wallet, so
 * nothing is handed over until there is one (`no_wallet` after
 * `TOKEN_TIMEOUT_MS`). The evidence is asked for first and the session proof
 * second, so the proof is never older than the evidence it is offered with. As
 * ash-template's `hasWallet` gate and token pair source.
 */
export async function handOver<S extends SignInState>(
  waitFor: (matches: (state: S) => boolean, timeoutMs: number) => Promise<S>,
  getIdentityToken: () => Promise<string | null>,
): Promise<Proof | Refusal> {
  let withWallet: S
  try {
    withWallet = await waitFor(one => one.authenticated && hasWallet(one.user), TOKEN_TIMEOUT_MS)
  } catch {
    return {ok: false, reason: "no_wallet"}
  }

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

/** Privy brings a Google or other redirect sign-in back to the page with this. As ash-template. */
export function returnedFromOAuth(search: string): boolean {
  return new URLSearchParams(search).has("privy_oauth_code")
}

function isToken(value: unknown): value is string {
  return typeof value === "string" && value.trim() !== ""
}
