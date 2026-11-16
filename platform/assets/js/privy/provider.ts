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
//
// The site's wallet chain (`walletChainId`), as Privy's own list of networks
// describes it, is the only network, so the Privy wallet starts on it and reads
// and sends through Privy's own nodes. A wallet app on another network is asked
// to switch as it connects (Privy leaves MetaMask through WalletConnect alone)
// and connects anyway if the person declines; a press asks again before it
// sends (`wallet_actions/send_step.ts`).
export function providerConfig(choices: SignInChoices, walletChain: Chain): PrivyClientConfig {
  const ethereum = {createOnLogin: "all-users"} as const
  const chains = {defaultChain: walletChain, supportedChains: [walletChain]}
  return choices === "email"
    ? {loginMethods: ["email"], embeddedWallets: {showWalletUIs: false, ethereum}, ...chains}
    : {embeddedWallets: {showWalletUIs: true, ethereum}, ...chains}
}

/** A network as Privy's settings take it. */
export type Chain = NonNullable<PrivyClientConfig["defaultChain"]>

// The chain the site's wallet buttons send on (`<meta name="wallet-chain-id">`,
// the server's `Patchbay.Offers.chain/0`).
export function walletChainId(doc: {querySelector(selectors: string): {getAttribute(name: string): string | null} | null}): number {
  return Number(doc.querySelector('meta[name="wallet-chain-id"]')?.getAttribute("content"))
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
