import type {PrivyClientConfig, User} from "@privy-io/react-auth"

// The sign-in choices (a wallet, email, Google and the others) come from the Privy
// dashboard. Everyone, including someone who signs in with their own wallet, gets
// a Privy Ethereum wallet (their Regents wallet) at their next sign-in, linked to
// their account, so every account can act. It is an ordinary wallet, never a smart
// wallet: SIWA checks its signatures without asking the chain. As ash-template's
// PrivyProvider (platform/assets/js/privy_bridge.tsx).
//
// The open address (`choices` "email") offers email as its only choice and shows
// none of Privy's wallet screens; the wallet is still made, so the sign-in
// finishes the same way.
export function providerConfig(choices: SignInChoices): PrivyClientConfig {
  const ethereum = {createOnLogin: "all-users"} as const
  return choices === "email"
    ? {loginMethods: ["email"], embeddedWallets: {showWalletUIs: false, ethereum}}
    : {embeddedWallets: {showWalletUIs: true, ethereum}}
}

// The page's sign-in choices (`<meta name="privy-sign-in">`): "email" at the open
// address, none at patchbay.help.
export type SignInChoices = "email" | null

export function signInChoices(doc: {querySelector(selectors: string): {getAttribute(name: string): string | null} | null}): SignInChoices {
  return doc.querySelector('meta[name="privy-sign-in"]')?.getAttribute("content") === "email" ? "email" : null
}

// A person who signs in with email or Google gets their Privy wallet just after
// Privy signs them in, and Patchbay's sign-in needs a wallet: the server refuses
// a Privy session with none. As ash-template's `hasWallet`.
export function hasWallet(user: Pick<User, "linkedAccounts"> | null | undefined): boolean {
  return (user?.linkedAccounts ?? []).some(account => account.type === "wallet" && account.chainType === "ethereum")
}
