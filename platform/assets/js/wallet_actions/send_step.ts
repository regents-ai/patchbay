// The template's `wallet_actions/send_step.ts`: addresses are compared
// lowercased rather than checksummed, so the page bundle does not carry an
// address library.

export type EthereumProvider = {
  request(args: {method: string; params?: unknown[]}): Promise<unknown>
}

/**
 * Privy's own way of moving one wallet to another network, which knows how each
 * wallet app asks to add a network it lacks. It rejects as the wallet does,
 * 4001 when the person says no.
 */
export type SwitchChain = (chainId: number) => Promise<void>

/**
 * The wallet a press signs with: its address, the provider it signs through
 * and Privy's own switch for it.
 */
export type SelectedWallet = {address: string; provider: EthereumProvider; switchChain: SwitchChain}

/**
 * The chain a step goes to. The server's review also names it and its public
 * node; the wallet takes those from Privy's own list of networks instead.
 */
export type StepChain = {chain_id: number}

/** One transaction a button sends, built on the server. */
export type TransactionStep = {kind: "transaction"; step: string; to: string; data: string; value: string}

/** One EIP-712 signature a button asks for, built on the server. */
export type SignatureStep = {kind: "signature"; step: string; typed_data: Record<string, unknown>}

/** Nothing reached the wallet's prompt; the reason picks the words the page shows. */
export class NothingSent extends Error {
  readonly reason: "wallet_unavailable" | "switch_declined" | "network_mismatch"

  constructor(reason: "wallet_unavailable" | "switch_declined" | "network_mismatch") {
    super(reason)
    this.reason = reason
  }
}

export type Failure = NothingSent["reason"] | "wallet_declined" | "sign_unconfirmed"

export type SendFailure = NothingSent["reason"] | "wallet_declined" | "insufficient_funds" | "send_unconfirmed"

/**
 * Sends one transaction from the signed-in wallet, after the same chain and
 * account reads as a signature, so a wallet that changes network part-way is
 * refused before it sees the transaction.
 */
export async function sendStep(
  chain: StepChain,
  signer: string,
  step: TransactionStep,
  wallet: SelectedWallet,
  sending: () => void,
): Promise<string> {
  const provider = await ready(chain, signer, wallet)

  sending()
  const hash = await provider.request({
    method: "eth_sendTransaction",
    params: [{from: signer, to: step.to, data: step.data, value: step.value}],
  })
  if (typeof hash !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(hash)) {
    throw new Error("The wallet did not return a transaction hash.")
  }
  return hash
}

/**
 * Asks the signed-in wallet to sign the server's typed data. Chain and account
 * are read again on every press, and `eth_chainId` is the last read before the
 * signature, so a wallet that changes network part-way is refused before it
 * sees what it would sign. Returns the signature only; the server keeps the
 * typed data it built.
 */
export async function signStep(
  chain: StepChain,
  signer: string,
  step: SignatureStep,
  wallet: SelectedWallet,
  signing: () => void,
): Promise<string> {
  const provider = await ready(chain, signer, wallet)

  signing()
  const signature = await provider.request({
    method: "eth_signTypedData_v4",
    params: [signer, JSON.stringify(step.typed_data)],
  })
  if (typeof signature !== "string" || !/^0x[0-9a-fA-F]{130}$/.test(signature)) {
    throw new Error("The wallet did not return a signature.")
  }
  return signature
}

/**
 * Why a press ended without a signature. Before `signing`, nothing reached the
 * wallet's prompt; after it, the wallet declined or did not say.
 */
export function failure(signing: boolean, error: unknown): Failure {
  if (!signing) return error instanceof NothingSent ? error.reason : "wallet_unavailable"
  return hasCode(error, 4001) ? "wallet_declined" : "sign_unconfirmed"
}

/** Why a press ended without a hash. After `sending`, the wallet may have sent it. */
export function sendFailure(sending: boolean, error: unknown): SendFailure {
  if (!sending) return error instanceof NothingSent ? error.reason : "wallet_unavailable"
  if (hasCode(error, 4001)) return "wallet_declined"
  // No EIP-1193 code names this; wallets and nodes all say it in these words.
  return hasMessage(error, /insufficient funds/i) ? "insufficient_funds" : "send_unconfirmed"
}

// The wallet is on the step's chain and account. A wallet on another chain is
// asked to switch on every press, through Privy's own switch: a person who says
// no hears that they did, and any other failure, or a wallet still elsewhere
// afterwards, is told to change network in the wallet app.
async function ready(
  chain: StepChain,
  signer: string,
  {provider, switchChain}: SelectedWallet,
): Promise<EthereumProvider> {
  if ((await chainId(provider)) !== chain.chain_id) {
    await switchChain(chain.chain_id).catch((error: unknown) => {
      throw new NothingSent(hasCode(error, 4001) ? "switch_declined" : "network_mismatch")
    })
  }

  const [account] = await accounts(provider)
  if (!account || account.toLowerCase() !== signer.toLowerCase()) throw new NothingSent("wallet_unavailable")
  if ((await chainId(provider)) !== chain.chain_id) throw new NothingSent("network_mismatch")
  return provider
}

/** The chain the wallet is on now; -1 when it does not say. */
export async function chainId(provider: EthereumProvider): Promise<number> {
  const value = await provider.request({method: "eth_chainId"})
  return typeof value === "string" && /^0x[0-9a-f]+$/i.test(value) ? Number(BigInt(value)) : -1
}

async function accounts(provider: EthereumProvider): Promise<string[]> {
  const value = await provider.request({method: "eth_accounts"})
  return Array.isArray(value) ? value.filter((a): a is string => typeof a === "string") : []
}

// Wallets wrap the EIP-1193 error in `cause` chains of their own.
function hasCode(error: unknown, code: number): boolean {
  return causes(error).some(e => (e as {code?: unknown}).code === code)
}

function hasMessage(error: unknown, words: RegExp): boolean {
  return causes(error).some(e => {
    const message = (e as {message?: unknown}).message
    return typeof message === "string" && words.test(message)
  })
}

function causes(error: unknown): object[] {
  const chain: object[] = []
  for (let e = error; e && typeof e === "object" && chain.length < 8; e = (e as {cause?: unknown}).cause) chain.push(e)
  return chain
}
