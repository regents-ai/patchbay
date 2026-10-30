import type {PrivyClientConfig, User} from "@privy-io/react-auth"

// The sign-in choices (a wallet, email, Google and the others) come from the Privy
// dashboard. Everyone, including someone who signs in with their own wallet, gets
// a Privy Ethereum wallet (their Regents wallet) at their next sign-in, linked to
// their account, so every account can act. It is an ordinary wallet, never a smart
// wallet: SIWA checks its signatures without asking the chain. As ash-template's
// PrivyProvider (platform/assets/js/privy_bridge.tsx).
export const providerConfig = {
  embeddedWallets: {showWalletUIs: true, ethereum: {createOnLogin: "all-users"}},
} satisfies PrivyClientConfig

// A person who signs in with email or Google gets their Privy wallet just after
// Privy signs them in, and Patchbay's sign-in needs a wallet: the server refuses
// a Privy session with none. As ash-template's `hasWallet`.
export function hasWallet(user: Pick<User, "linkedAccounts"> | null | undefined): boolean {
  return (user?.linkedAccounts ?? []).some(account => account.type === "wallet" && account.chainType === "ethereum")
}
