// The payments lab's stand-in wallet app, after the template's
// `onchain_lab.ts`. It holds anvil's first three accounts, one provider each,
// and signs through the lab page on the lab's copy of Base; the network, a
// refused switch, a decline, a slow answer and a signature ending in 0 or 1
// are the tester's to set. The Tip button runs the page's own `payForIntent`
// with this wallet in Privy's place, and every press reaches it.
import {payForIntent} from "./webmcp/paid_actions.js"

const LAB_CHAIN_ID = 8453
const root = document.getElementById("lab-wallet")
const csrfToken = document.querySelector('meta[name="csrf-token"]').content
const field = name => root.querySelector(`[name="${name}"]:checked`)
const ticked = name => field(name) !== null
const log = words => { root.querySelector("[data-lab-log]").textContent = words }
let chainId = Number(field("lab-network").value)

root.addEventListener("change", event => {
  if (event.target.name === "lab-network") chainId = Number(event.target.value)
})

function provider(address) {
  return {
    request: async ({method, params = []}) => {
      if (ticked("lab-slow")) await new Promise(resolve => setTimeout(resolve, 1500))
      switch (method) {
        case "eth_chainId":
          return `0x${chainId.toString(16)}`
        case "eth_accounts":
          return [address]
        case "wallet_switchEthereumChain": {
          if (ticked("lab-refuse-switch")) throw rpcError(4001, "User rejected the request.")
          const wanted = Number(BigInt(params[0].chainId))
          if (wanted !== LAB_CHAIN_ID && wanted !== 1) throw rpcError(4902, "Unrecognized chain.")
          chainId = wanted
          root.querySelector(`[name="lab-network"][value="${wanted}"]`).checked = true
          log(`The wallet switched to network ${wanted}.`)
          return null
        }
        case "eth_signTypedData_v4": {
          if (ticked("lab-decline")) {
            log("The wallet declined.")
            throw rpcError(4001, "User rejected the request.")
          }
          if (chainId !== LAB_CHAIN_ID) throw rpcError(-32603, "This wallet can only sign on the lab chain.")
          const response = await fetch("/dev/lab/payments/wallet", {
            method: "POST",
            headers: {"content-type": "application/json", accept: "application/json", "x-csrf-token": csrfToken},
            body: JSON.stringify({method, params}),
          })
          const reply = await response.json()
          if (reply.error) throw rpcError(reply.error.code, reply.error.message)
          log("The wallet signed.")
          return ticked("lab-low-v") ? lowRecoveryId(reply.result) : reply.result
        }
        default:
          throw rpcError(4200, `The lab wallet does not support ${method}.`)
      }
    },
  }
}

const providers = new Map(
  [...root.querySelectorAll('[name="lab-wallet"]')]
    .filter(input => input.value)
    .map(input => [input.value, provider(input.value)]),
)

// Privy's part: the open wallet, or none, when the press asks.
async function wallet() {
  const address = field("lab-wallet").value
  if (!address) {
    log("The press asked the wallet app to connect. Choose a wallet above.")
    return {ok: false, reason: "wallet_unavailable"}
  }
  return {ok: true, wallet: {address, provider: providers.get(address)}}
}

const form = document.getElementById("lab-tip")
const results = document.getElementById("lab-results")

form.addEventListener("submit", async event => {
  event.preventDefault()
  const line = document.createElement("li")
  line.textContent = "Paying…"
  results.prepend(line)
  const outcome = await payForIntent(
    {csrfToken, document, wallet},
    {kind: "agent_tip", args: {profile_id: form.dataset.recipient, amount_usdc: form.elements.amount.value}},
  )
  line.textContent = JSON.stringify({status: outcome.status, unsigned: outcome.unsigned, body: outcome.body})
})

// Some wallets end a signature with 0 or 1 where others write 27 or 28.
function lowRecoveryId(signature) {
  const v = parseInt(signature.slice(-2), 16) - 27
  return signature.slice(0, -2) + v.toString(16).padStart(2, "0")
}

function rpcError(code, message) {
  return Object.assign(new Error(message), {code})
}
