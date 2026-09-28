// The template's `wallet_actions/send_step.ts` signing half: addresses are
// compared lowercased rather than checksummed, so the page bundle does not
// carry an address library.

export type EthereumProvider = {
  request(args: {method: string; params?: unknown[]}): Promise<unknown>
}

/** The wallet a press signs with: its address and the provider it signs through. */
export type SelectedWallet = {address: string; provider: EthereumProvider}

/** The chain a step goes to, as the server names it for the wallet's prompt. */
export type StepChain = {chain_id: number; name: string; rpc_url: string}

/** One EIP-712 signature a button asks for, built on the server. */
export type SignatureStep = {kind: "signature"; step: string; typed_data: Record<string, unknown>}

/** Nothing reached the wallet's signing prompt; the reason picks the words the page shows. */
export class NothingSigned extends Error {
  readonly reason: "wallet_unavailable" | "network_mismatch"

  constructor(reason: "wallet_unavailable" | "network_mismatch") {
    super(reason)
    this.reason = reason
  }
}

export type Failure = NothingSigned["reason"] | "wallet_declined" | "sign_unconfirmed"

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
  if (!signing) return error instanceof NothingSigned ? error.reason : "wallet_unavailable"
  return hasCode(error, 4001) ? "wallet_declined" : "sign_unconfirmed"
}

// The wallet is on the step's chain and account.
async function ready(
  chain: StepChain,
  signer: string,
  {provider}: SelectedWallet,
): Promise<EthereumProvider> {

  if ((await chainId(provider)) !== chain.chain_id) await switchChain(provider, chain)

  const [account] = await accounts(provider)
  if (!account || account.toLowerCase() !== signer.toLowerCase()) throw new NothingSigned("wallet_unavailable")
  if ((await chainId(provider)) !== chain.chain_id) throw new NothingSigned("network_mismatch")
  return provider
}

async function switchChain(provider: EthereumProvider, chain: StepChain): Promise<void> {
  const chainId = `0x${chain.chain_id.toString(16)}`
  try {
    try {
      await provider.request({method: "wallet_switchEthereumChain", params: [{chainId}]})
    } catch (error) {
      if (!hasCode(error, 4902)) throw error
      await provider.request({
        method: "wallet_addEthereumChain",
        params: [{
          chainId,
          chainName: chain.name,
          nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18},
          rpcUrls: [chain.rpc_url],
        }],
      })
      await provider.request({method: "wallet_switchEthereumChain", params: [{chainId}]})
    }
  } catch {
    throw new NothingSigned("network_mismatch")
  }
}

async function chainId(provider: EthereumProvider): Promise<number> {
  const value = await provider.request({method: "eth_chainId"})
  return typeof value === "string" && /^0x[0-9a-f]+$/i.test(value) ? Number(BigInt(value)) : -1
}

async function accounts(provider: EthereumProvider): Promise<string[]> {
  const value = await provider.request({method: "eth_accounts"})
  return Array.isArray(value) ? value.filter((a): a is string => typeof a === "string") : []
}

// Wallets wrap the EIP-1193 error in `cause` chains of their own.
function hasCode(error: unknown, code: number): boolean {
  const chain: object[] = []
  for (let e = error; e && typeof e === "object" && chain.length < 8; e = (e as {cause?: unknown}).cause) chain.push(e)
  return chain.some(e => (e as {code?: unknown}).code === code)
}
