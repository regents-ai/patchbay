# Going live: the escrow contract and the paid site

The site itself is already up at <https://patchbay.help> and every unpaid part
of it works. This sheet is the rest: the money. Follow it in order — each step
assumes the one before it is done.

Four things are set on the Fly app today: `PHX_HOST`, `SECRET_KEY_BASE`,
`DATABASE_URL` and `OPENAI_API_KEY`. Everything below is what is missing.

Two rules that apply throughout:

- **Every `fly secrets set` restarts the machine.** Never run one while a
  `fly deploy` is in flight, and never run two at the same time.
- **Every step that signs something is the founder's.** Deploying the contract,
  funding the operator wallet and setting secrets are done by a person with the
  keys, not by an agent.

## What you need before you start

| Thing | What it is |
| --- | --- |
| A Base mainnet RPC endpoint | From Alchemy, QuickNode, or Coinbase. It usually carries your key in the URL, so it is kept as a secret. |
| The treasury address | The Regents splitter contract that takes the 10%. Fixed at deployment and can never be changed afterwards, so be certain of it. |
| An operator wallet | A fresh EOA whose only job is to sign Patchbay's `credit` and `release` calls. It needs a little ETH on Base for gas — 0.01 ETH is plenty for a demo. |
| An owner address | Ideally a hardware wallet or Safe. It can only repoint the operator; it can never move money. The deployer becomes the owner, so deploy from this address or hand ownership over afterwards. |
| A Privy app | From <https://dashboard.privy.io>. You need its app id and its verification key. |
| Coinbase Developer Platform keys | From <https://portal.cdp.coinbase.com>. These are the x402 facilitator's credentials. |
| An Etherscan API key | Only for `--verify` on the contract deployment. |

## 1. Deploy the escrow contract on Base

From `repos/patchbay/contracts`. Set the environment first, in your own shell:

```sh
export BASE_RPC_URL="https://<your Base mainnet endpoint>"
export TREASURY="0x<the Regents splitter address>"
export OPERATOR="0x<the operator wallet address>"
export ETHERSCAN_API_KEY="<your Etherscan key>"
```

`USDC` is optional and defaults to Circle's native USDC on Base,
`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`. Leave it unset.

Rehearse against a fork first. This never broadcasts:

```sh
forge script script/Sanity.s.sol --rpc-url $BASE_RPC_URL
```

Then deploy for real, signing with your hardware wallet:

```sh
forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify --ledger
```

Use `--account <name>` instead of `--ledger` for a Foundry keystore entry. The
script prints the deployed address along with the token, treasury, operator and
owner it was given. **Write the deployed address down** — it is the only thing
from this step the site needs.

Check the printed treasury and operator against what you meant, because the
treasury can never be changed.

If you deployed from a hot key rather than the address you want owning it, hand
ownership over now: call `transferOwnership` from the deployer, then
`acceptOwnership` from the new owner.

## 2. Turn on sign-in

In the Privy dashboard, add `patchbay.help` to the app's allowed domains first,
or sign-in will be refused at the browser. Then:

```sh
fly secrets set --app patchbay-regents PRIVY_APP_ID="<your Privy app id>"
```

Wait for the machine to come back, then:

```sh
fly secrets set --app patchbay-regents PRIVY_VERIFICATION_KEY="$(cat /path/to/privy-verification-key.pem)"
```

Fly hands multi-line secrets back with the newlines escaped; the site accepts
both spellings, so nothing special is needed here.

Sign-in is wallet-only today. An account that signs in with email or a social
login has no wallet address, so it cannot tip or be tipped, unless Privy
embedded wallets are turned on for the app.

## 3. Turn on payments

```sh
fly secrets set --app patchbay-regents CDP_API_KEY_ID="<your CDP key id>"
```

Wait for the restart, then:

```sh
fly secrets set --app patchbay-regents CDP_API_KEY_SECRET="<your CDP key secret>"
```

Then the endpoint the site reads Base through:

```sh
fly secrets set --app patchbay-regents BASE_RPC_URL="https://<your Base mainnet endpoint>"
```

`X402_FACILITATOR_URL` does not need setting. Without it the site uses
Coinbase's hosted facilitator, which is the right one for Base mainnet.

## 4. Point the site at the contract

```sh
fly secrets set --app patchbay-regents ESCROW_CONTRACT_ADDRESS="0x<the address step 1 printed>"
```

Wait for the restart, then the operator key:

```sh
fly secrets set --app patchbay-regents OPERATOR_PRIVATE_KEY="0x<the operator wallet private key>"
```

This is the one secret whose loss costs money: it can misdirect anything already
in escrow. It cannot mint, cannot change the 90/10 split and cannot take the
treasury's share. If it ever leaks, the owner calls `setOperator` with a fresh
address and you set this secret again.

Make sure the operator wallet holds a little ETH on Base before the first paid
post, or the recording transaction will simply fail.

## 5. Deploy the current code

Only the current tree may be deployed: the escrow contract changed when the
thirty-day refund went in, and the site is compiled against its ABI.

From `repos/patchbay`, confirm you are clean and level with the remote:

```sh
git status --short && git rev-parse HEAD origin/main
```

Both hashes must match and there must be no output from `git status`. Then:

```sh
fly deploy --app patchbay-regents --remote-only --ha=false
```

## 6. Verify

```sh
curl -s https://patchbay.help/webmcp/health
```

Then in a browser: sign in with a wallet, post a question with a bounty, and
check that the money card on the report page names the contract and shows the
date thirty days out. `fly logs --app patchbay-regents` shows the recording
transaction going out.

## Rolling back

`fly releases --app patchbay-regents` lists the deploys and
`fly deploy --app patchbay-regents --image <previous image>` puts one back. The
contract cannot be rolled back — it has no upgrade path and no pause. If it is
wrong, deploy a new one and change `ESCROW_CONTRACT_ADDRESS`; money already in
the old contract is still refundable to its askers thirty days on.
