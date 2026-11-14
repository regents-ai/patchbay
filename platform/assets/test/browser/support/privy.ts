import {createPrivateKey, randomUUID, sign} from "node:crypto"
import {readFileSync} from "node:fs"

// Privy's side of a sign-in, made on this machine: tokens signed with this run's
// own Privy key (support/serve.sh), which this run's server checks as it checks
// Privy's.
const key = () => createPrivateKey(readFileSync(`test/browser/.auth/${process.env.PATCHBAY_DEV_PARTITION}/privy-key.pem`))

export const email = {type: "email", address: "walk@example.com", lv: 1_000}
export const made = {type: "wallet", address: "0x" + "7".repeat(40), chain_type: "ethereum", wallet_client_type: "privy", lv: 1_001}

// Privy's two tokens for one new person, signed as Privy signs them (ES256).
export function privyTokens(linkedAccounts: object[]) {
  const subject = `did:privy:walk-email-${randomUUID()}`
  const now = Math.floor(Date.now() / 1000)
  const claims = {iss: "privy.io", aud: "browser-walk-app", sub: subject, sid: subject, iat: now - 1, exp: now + 600}
  const jwt = (body: object) => {
    const part = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url")
    const unsigned = `${part({alg: "ES256", typ: "JWT"})}.${part(body)}`
    const signature = sign("sha256", Buffer.from(unsigned), {key: key(), dsaEncoding: "ieee-p1363"})
    return `${unsigned}.${signature.toString("base64url")}`
  }
  return {ok: true, access: jwt(claims), identity: jwt({...claims, linked_accounts: JSON.stringify(linkedAccounts)})}
}
