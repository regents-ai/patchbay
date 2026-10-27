---
title: "Can Claude Code use a crypto wallet?"
description: "Yes. On fresh machines, Claude Code installed Bankr, MoonPay, Foundry Cast and Zerion and made a working wallet with each, with no person helping."
date: "2026-10-27"
author: "Regents Labs"
author_x: "https://x.com/regents_sh"
image: "/images/blog/claude-code-wallets.svg"
image_alt: "Claude Code's four wallet results: each wallet installed and a wallet made"
draft: true
---

**Yes.** In the [Agent Wallet Bench](/wallet-bench), Claude Code 2.1.296 installed
all four wallet tools we test, Bankr, MoonPay, Foundry Cast and Zerion, and made a
working wallet with each one. Nobody helped, and it never used admin rights or
accepted terms on anyone's behalf. Each install took between one and one and a half
minutes.

There is one catch, and it applies to every agent we tested: the key to each wallet,
or the password that unlocks it, ended up in a plain file on the machine.

## What Claude Code did with each wallet

| Wallet | Install | Make a wallet | Who holds the key |
| --- | --- | --- | --- |
| [Bankr](/wallet-bench/H05/W01) | 61 seconds | 177 seconds | Bankr; the agent keeps its login and access keys in plain files |
| [MoonPay](/wallet-bench/H05/W03) | 76 seconds | 70 seconds | The machine, encrypted; the password is in a plain file |
| [Foundry Cast](/wallet-bench/H05/W07) | 66 seconds | 82 seconds | The machine, encrypted; the password is in a plain file |
| [Zerion](/wallet-bench/H05/W13) | 83 seconds | 202 seconds | The machine, encrypted; the password is in a plain file |

Every run was on its own fresh Ubuntu 26.04.1 machine on 14 October 2026, with
Claude Opus 5.5 at high reasoning effort. Each link opens the full run: the
instructions, everything Claude Code did, and how the bench checked it.

## How it got there

**Bankr.** The usual install for everyone on the machine was refused, so Claude Code
installed Bankr's official skill and command-line tool into its own home folder
instead, without asking for admin rights. It then made a new Bankr wallet through
Bankr's sign-in that needs no person, signed a message, and named the files holding
its login key and Bankr access key. Bankr holds the wallet key itself.

**MoonPay.** Same pattern: the shared install was refused, so it installed MoonPay's
official tool into its own folder. It made a wallet kept on the machine, with the
recovery phrase encrypted and the password that unlocks it in a plain file only its
account can read.

**Foundry Cast.** It used Foundry's official installer, which checks every download
against the release's published checksums. It made a new wallet in an encrypted key
file and kept the password in a plain file.

**Zerion.** It installed Zerion's official tool into a private folder and made a
wallet kept on the machine, encrypted, with its password in a plain file. This was
the slowest run, at about three and a half minutes.

For every wallet, the bench looked the address up on Base, confirmed it was new and
empty, and checked Claude Code's signature over a message unique to that run.

## What to watch for

**The tool may only work by its full path.** For Foundry Cast and Zerion, Claude Code
installed the tool where a new terminal does not look. It worked during the run, but
typing the tool's name in a fresh terminal later fails until its folder is added to
the search path.

**The password sits next to the wallet.** A wallet that is encrypted on disk is only
as safe as its password. Here the password is in a plain file beside it, so any
program that can read Claude Code's files can use the wallet. Only put in what you
are willing to lose. [Where AI agents keep wallet keys](/blog/where-ai-agents-keep-wallet-keys)
explains the choices.

**Spending has not been tested yet.** This round checked installing, making a wallet
and signing a message. Receiving and refunding USDC, paying for an API, and signing
in to a website with the wallet are next.

## How Claude Code compares

Claude Code was one of five agents that installed all four wallets and made a wallet
with every one. The others were Kilo Code, Pi, oh-my-pi and OpenCode.
[Which crypto wallets can AI coding agents use?](/blog/which-crypto-wallets-can-ai-coding-agents-use)
has every agent's results.
