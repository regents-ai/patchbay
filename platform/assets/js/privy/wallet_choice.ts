type Wallet = {address: string; type?: string}

/**
 * Privy's active wallet when this tab still holds it connected and, signed in,
 * the account links it. A wallet app left open on a wallet the account does not
 * link is ignored. As ash-template's `accountActiveWallet`.
 */
export function accountActiveWallet<W extends {address: string}>(
  active: W | null,
  wallets: ReadonlyArray<{address: string}>,
  authenticated: boolean,
  linked: ReadonlyArray<string>,
): W | null {
  if (!active) return null
  const address = active.address.toLowerCase()
  const held = wallets.some(wallet => wallet.address.toLowerCase() === address)
  return held && (!authenticated || linked.includes(address)) ? active : null
}

/**
 * The wallet that sends for the signed-in account. Privy's active Ethereum wallet
 * when the account links it. Privy names no wallet after a sign-in that skipped
 * its window, or in a new tab, and an active wallet the account does not link is
 * no wallet: the signed-in wallet then sends as this tab has it connected, the one
 * connected wallet the account is linked to, or, when this tab has several, the
 * account's own wallet the page was drawn for (`own`). Several and none of them
 * the account's own is no wallet. `linked` is the account's wallets as Patchbay
 * verified them at sign-in (`data-account-wallets`), the list the server lets pay.
 * As ash-template's wallet sync.
 */
export function sendingWallet<W extends Wallet>(
  active: Wallet | null | undefined,
  wallets: ReadonlyArray<W>,
  linked: ReadonlyArray<string>,
  own: string | null,
): W | null {
  const selected = accountActiveWallet(active?.type === "ethereum" ? active : null, wallets, true, linked)
  // The connected wallet Privy's selection names, as this tab holds it.
  const held = selected && wallets.find(wallet => wallet.address.toLowerCase() === selected.address.toLowerCase())
  if (held) return held

  const signedIn = wallets.filter(wallet => wallet.type === "ethereum" && linked.includes(wallet.address.toLowerCase()))
  const chosen = signedIn.length === 1 ? signedIn : signedIn.filter(wallet => wallet.address.toLowerCase() === own)
  return chosen.length === 1 ? chosen[0] : null
}
