# Going live: the escrow contract and the paid site

The site itself is already up at <https://patchbay.help> and every unpaid part
of it works. This sheet is the rest: the money. Follow it in order — each step
assumes the one before it is done.

These are set on the Fly app today: `PHX_HOST`, `SECRET_KEY_BASE`,
`DATABASE_POOLED_URL`, `DATABASE_DIRECT_URL` and `OPENAI_API_KEY`. Everything below is what is missing.

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
| An owner address | Ideally a hardware wallet or Safe. Set it as `OWNER`. It is the owner from construction. It can only repoint the operator; it can never move money. |
| A Privy app | From <https://dashboard.privy.io>. You need its app id and its verification key. |
| Coinbase Developer Platform keys | From <https://portal.cdp.coinbase.com>. These are the x402 facilitator's credentials. |
| An Etherscan API key | Only for `--verify` on the contract deployment. |

## 1. Deploy the escrow contract on Base

From `repos/patchbay/contracts`. Set the environment first, in your own shell:

```sh
export BASE_RPC_URL="https://<your Base mainnet endpoint>"
export TREASURY="0x<the Regents splitter address>"
export OPERATOR="0x<the operator wallet address>"
export OWNER="0x<the owner address, typically a Safe>"
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
Ledger still signs; it is not the owner unless `OWNER` equals the signer. The
script prints the deployed address along with the token, treasury, operator and
owner it was given. **Write the deployed address down** — it is the only thing
from this step the site needs.

Check the printed treasury, operator and owner against what you meant, because
the treasury can never be changed and `OWNER` is the owner from construction.

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

The sign-in choices (a wallet, email, Google and the others) come from the
Privy dashboard. Privy makes every person an Ethereum wallet of their own when
they sign in, and the page hands the sign-in to Patchbay only once that wallet
exists, so an email or social account can tip and be tipped like a wallet
sign-in. To offer email, turn it on under the Privy app's login methods.

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

From `repos/patchbay`:

Push the commit to `main`, then:

```sh
scripts/deploy.sh
```

It refuses to run while `git status` shows a change or while `origin/main` does
not contain the commit.

## 6. Verify

```sh
curl -s https://patchbay.help/capabilities.json
```

Its `build.commit` must be the commit you deployed.

Then in a browser: sign in, post a question with a bounty, and
check that the money card on the report page names the contract and shows the
date thirty days out. `fly logs --app patchbay-regents` shows the recording
transaction going out.

## Rolling back

`fly releases --app patchbay-regents` lists the deploys and
`fly deploy --app patchbay-regents --image <previous image>` puts one back. The
contract cannot be rolled back — it has no upgrade path and no pause. If it is
wrong, deploy a new one and change `ESCROW_CONTRACT_ADDRESS`; money already in
the old contract is still refundable to its askers thirty days on.

## Offers

Agent offers stay off in production (`/offers` and the agent reads answer 404)
until the market's settings below are set. Once they are, the site reads the
market every five minutes on its own. **Deploying the contracts (step 1) and
setting the secrets (step 3) each need Sean's own go**; an agent prepares and
checks everything else.

Before you start:

- **The publisher wallet.** A fresh EOA. It signs Patchbay's admissions, so the
  site holds its key, and it never holds money. It sends the three deploy
  transactions, so it needs a little ETH on Base. Keep its key in a Foundry
  keystore entry (`cast wallet import <name> --interactive`).
- **The admin.** The factory's owner, who admits other publishers and sets the
  operator. Ideally a Safe.
- **The operator.** Only the operator or the Safe may send to staking: each
  market's 10% share and Patchbay's earnings. The admin can replace it later.
- **The REGENT revenue staking contract**, the one `STAKING_CONTRACT_ADDRESS`
  names.
- **`BASE_RPC_URL` set on the Fly app** ("3. Turn on payments" above):
  production reads the market through it.

1. **Deploy the contracts** (Sean's go). From `repos/patchbay/contracts`, with
   `OFFERS_ADMIN`, `OFFERS_OPERATOR`, `OFFERS_PUBLISHER`, `OFFERS_STAKING`,
   `OFFERS_FEE_BPS` (1000), `BASE_RPC_URL` and `ETHERSCAN_API_KEY` set in your
   shell. Run it once without `--broadcast` to simulate, then:

   ```sh
   forge script script/DeployOffers.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify --account <publisher keystore name>
   ```

   `contracts/README.md`, "Deploy the offer contracts", says what the script
   checks and logs.

2. **Record the addresses.** Write down the factory, staking payout and market
   addresses the script logs, and the block number forge prints for the last of
   the three transactions (`createMarket`). Check the owner, operator, staking
   contract, fee, publisher and payout it logs against what you meant. Only the
   owner's role and the operator can change later, and only by the owner.

3. **Set the three secrets** (Sean's go). The publisher key never goes on a
   command line, in a chat or in a log: it is read from a file only this step
   reads, on standard input. The file holds one line,
   `PATCHBAY_OFFERS_PUBLISHER_KEY=0x<the publisher key>`. All three are staged
   and then applied together, so the machine restarts once:

   ```sh
   fly secrets import --stage --app patchbay-regents < <the key file>
   fly secrets set --stage --app patchbay-regents PATCHBAY_OFFERS_MARKET="0x<the market address>" PATCHBAY_OFFERS_FROM_BLOCK="<the createMarket block>"
   fly secrets deploy --app patchbay-regents
   ```

   The block is required with the market. A malformed address or block stops
   the machine's boot with a message naming the setting, never its value; set
   it again correctly. A missing or malformed key leaves buying closed.

4. **Release** the current `main` with `scripts/deploy.sh`, as in "5. Deploy the
   current code" above, if the commit that reads these settings in production
   is not live yet.

5. **Confirm.** <https://patchbay.help/offers> answers with the Offers page
   instead of the 404 page, and so do `/offers.md` and `/api/offers`;
   <https://open.patchbay.help/offers> still answers 404. The market starts with
   no placements, so the page lists none until the publisher creates Patchbay's
   own on the market.

To switch Offers off again, `fly secrets unset --app patchbay-regents
PATCHBAY_OFFERS_MARKET`. The contracts stay on Base, and every credit in them
can still be claimed there.
