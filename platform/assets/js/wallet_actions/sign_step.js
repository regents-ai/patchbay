// The template's `wallet_actions/send_step.ts` signing half, for Patchbay's
// plain-JavaScript pages: addresses are compared lowercased rather than
// checksummed, so the page bundle does not carry an address library.

/** Nothing reached the wallet's signing prompt; the reason picks the words the page shows. */
export class NothingSigned extends Error {
  /** @param {"wallet_unavailable" | "network_mismatch"} reason */
  constructor(reason) {
    super(reason)
    this.reason = reason
  }
}

/**
 * Asks the signed-in wallet to sign the server's typed data. Chain and account
 * are read again on every press, and `eth_chainId` is the last read before the
 * signature, so a wallet that changes network part-way is refused before it
 * sees what it would sign. Returns the signature only; the server keeps the
 * typed data it built.
 *
 * @param {{chain_id: number, name: string, rpc_url: string}} chain
 * @param {string} signer
 * @param {{typed_data: object}} step
 * @param {() => {address: string, provider: {request: Function}} | null} wallet
 * @param {() => void} signing
 * @returns {Promise<string>}
 */
export async function signStep(chain, signer, step, wallet, signing) {
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
 *
 * @param {boolean} signing
 * @param {unknown} error
 * @returns {"wallet_unavailable" | "network_mismatch" | "wallet_declined" | "sign_unconfirmed"}
 */
export function failure(signing, error) {
  if (!signing) return error instanceof NothingSigned ? error.reason : "wallet_unavailable"
  return hasCode(error, 4001) ? "wallet_declined" : "sign_unconfirmed"
}

// The wallet is on the step's chain and account, and still the one Privy holds.
async function ready(chain, signer, wallet) {
  const selected = wallet()
  if (!selected) throw new NothingSigned("wallet_unavailable")
  const {provider} = selected

  if ((await chainId(provider)) !== chain.chain_id) await switchChain(provider, chain)

  const [account] = await accounts(provider)
  if (!account || account.toLowerCase() !== signer.toLowerCase()) throw new NothingSigned("wallet_unavailable")
  if ((await chainId(provider)) !== chain.chain_id) throw new NothingSigned("network_mismatch")
  // Privy may have swapped the wallet during those reads; this check makes no request.
  if (wallet()?.provider !== provider) throw new NothingSigned("wallet_unavailable")
  return provider
}

async function switchChain(provider, chain) {
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

async function chainId(provider) {
  const value = await provider.request({method: "eth_chainId"})
  return typeof value === "string" && /^0x[0-9a-f]+$/i.test(value) ? Number(BigInt(value)) : -1
}

async function accounts(provider) {
  const value = await provider.request({method: "eth_accounts"})
  return Array.isArray(value) ? value.filter(a => typeof a === "string") : []
}

// Wallets wrap the EIP-1193 error in `cause` chains of their own.
function hasCode(error, code) {
  const chain = []
  for (let e = error; e && typeof e === "object" && chain.length < 8; e = e.cause) chain.push(e)
  return chain.some(e => e.code === code)
}
