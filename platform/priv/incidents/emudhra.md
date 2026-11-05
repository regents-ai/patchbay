---
title: "eMudhra: private keys of 8 certificate authorities can be recovered"
summary: "Browsers block the bad certificates. Servers, containers, developer tools and some apps may still trust them. Test the client you use, then update its trust store."
date: "2026-10-20"
checked: "2026-11-05"
status: active
tag: "emudhra"
post_site: "emudhra.com"
check_again: "On 9 November 2026, when eMudhra's full incident report is due, and when Apple ships its fix for macOS developer tools"
---

## Summary

- The private keys of 8 eMudhra intermediate certificate authorities (CAs) can be worked out from their public certificates. Six issue TLS certificates and two issue code-signing certificates.
- With a TLS key, anyone can make a certificate for any website or service.
- A person named Wayne reported this to the root programs on 17 October 2026, and the matter became public on 20 October. Mozilla says several people recovered the keys on their own, some publicly.
- eMudhra revoked all 8 on 18 October. Sectigo revoked its cross-signs by 19 October. Mozilla and Chrome are removing trust in the root "emSign ECC Root CA - G3". Mozilla is keeping "emSign Root CA - G1" for now.
- eMudhra says it will leave the public TLS business. Its full incident report, with KPMG's review, is due by 9 November 2026.

## Exposure

- **Browsers:** blocked in Firefox and Chrome since 17 October, on Microsoft platforms since 20 October and on Apple products since 22 October.
- **Non-browser clients:** still at risk until updated. Many do not read revocation information and ship their own CA list. This covers servers, containers, language runtimes, libraries and agents.
- **macOS developer tools:** on 28 October, the test site reported that the built-in `git`, `curl` and `python3` still trust these certificates. They read `/etc/ssl/cert.pem` and skip revocation. It also reported that macOS 27.2 undid fixes users had applied. The test site says Apple will update that file in a future macOS update.
- **Electron apps:** apps such as Slack and Discord need a version rebuilt on a patched Electron. Updating the operating system is not enough.
- **Site owners:** eMudhra reports about 30,800 certificates under the affected hierarchies, for one US client group, and says they moved to its G1 RSA root. InCommon, a certificate service, said on 22 October that eMudhra would stop issuing from these chains in about 30 days, with the date still to be confirmed.

**Exploitation**

- No source we opened shows the keys being used against a real victim.
- The test site found no certificate transparency (CT) entries for these intermediates from April 2025 until disclosure, and it rules out attacks in that period on browsers that enforce CT. It does not know about clients that do not enforce CT. `curl` is one such client.
- eMudhra says it knows of no evidence the keys were recovered or used before disclosure. That is the company's own statement.
- Since disclosure, certificates signed with these keys do exist. A community report in the Mozilla bug counts 107,107 logged on 20 and 21 October, most of them proof-of-concept certificates for `google.com`. We could not check the count ourselves. It also says most carry no revocation pointer, so a client that checks only the final certificate finds nothing.

**Still open**

- The root cause is not settled. On 2 November, eMudhra said its earlier answers came from internal analysis and that KPMG was now reviewing the matter.
- Mozilla had not checked eMudhra's RSA keys at the time of its first review. Participants in the bug have questioned eMudhra's answers on the RSA keys and on a revocation list signed with the wrong key.

## Actions

1. Test from the same client your program uses. A browser test tells you nothing about your server.
   ```
   curl https://dv-g3b-emudhra.we-have-a-problem.com/
   curl https://dv-g3b-aaa-emudhra.we-have-a-problem.com/
   ```
   A certificate error is the good result: the client refuses these CAs. A page means it still accepts them. A TLS-intercepting proxy changes the result, because you are then testing the proxy.
2. Run the two hosts below as well. A page here means the client trusts these CAs and also accepts certificates never logged to CT, which is the case an attacker could use unnoticed.
   ```
   curl https://dv-g3b-noct-emudhra.we-have-a-problem.com/
   curl https://dv-g3b-aaa-noct-emudhra.we-have-a-problem.com/
   ```
3. Update the trust store or runtime your program uses. Fixed versions:
   - Debian `ca-certificates` 20250419~deb12u2, 20250419+deb13u1, 20260816+nmu1
   - Ubuntu `ca-certificates` 20260816ubuntu0.22.04.1, .24.04.1, .26.04.1, .26.10.1
   - Alpine `ca-certificates` 20261020-r0
   - Fedora 2026.2.92_v9.0.319. RHEL 2026.2.92_v9.0.319 with -60.3.el6_10, -70.3.el7_9, -81.3.el8_10, -90.3.el9_8 or -100.3.el10_2
   - Homebrew `ca-certificates` 2026-09-25_1. curl CA bundle 2026-10-20. NSS 3.131.1
   - Node.js 26.12.1, 24.22.1, 22.23.4
   - Bun 1.4.4. Deno 2.9.8
   - Go 1.27.3, 1.26.10
   - Python 3.15.2, 3.14.10, 3.13.18, 3.12.16, 3.11.18. certifi 2026.10.19. pip 26.2.2. uv 0.13.5
   - Elixir castore 1.0.22. Erlang certifi 2.18.0
   - Rust webpki-roots and webpki-root-certs 1.0.10. rustls-webpki 0.103.16
   - Composer ca-bundle 1.4.16, 1.6.0
   - Electron 44.9.1, 43.8.1, 42.11.16
   - Docker CLI and Engine 29.9.2. Docker Desktop 4.96.2
4. Rebuild container images and restart services, so the new list is really in use. On Node.js, sessions resumed from before the update are not checked again.
5. On Debian or Ubuntu with their OpenJDK, the Java keystore does not refresh by itself. As root, run `rm -f /etc/ssl/certs/java/cacerts && update-ca-certificates --fresh`.
6. Watch for software without a fix. The test site listed these as pending when we checked: OpenJDK, certbot, containerd, Godot, LibreOffice, TrueNAS, Bottlerocket, OpenHarmony and Apple's command-line tools. Its list changes often.
7. On macOS, the test site gives expert steps to remove the roots from `/etc/ssl/cert.pem`. A macOS update may replace that file, so repeat the test after each update. Removing "AAA Certificate Services" can break unaffected sites.
8. If your site uses a certificate that chains to emSign ECC Root CA - G3, replace it. InCommon customers should reissue as RSA, as its notice asks.
9. Never answer a certificate error by turning off certificate checks.

## Sources

- [Mozilla bug 2083449](https://bugzilla.mozilla.org/show_bug.cgi?id=2083449): incident record. Report, weak keys, revocation times, root removal, exit from public TLS, open questions, KPMG, community CT count.
- [eMudhra CA compromise test site](https://emudhra.we-have-a-problem.com): community research published by Dennis Jackson. Block dates, test hosts, patched and pending versions, macOS and Java notes, CT finding.
- [eMudhra incident page](https://emudhra.com/en/post/certificate-security-incident): vendor statement. Certificate count, move to G1, KPMG, its statement on evidence.
- [InCommon notice](https://incommon.org/about/news/incommon-certificate-service-update): customer notice. Stop in issuance, RSA reissue.
- [Node.js pull request 66871](https://github.com/nodejs/node/pull/66871): vendor code change. The fix, and how resumed sessions behave.
- [Node.js 22 changelog](https://github.com/nodejs/node/blob/main/doc/changelogs/CHANGELOG_V22.md), [24 changelog](https://github.com/nodejs/node/blob/main/doc/changelogs/CHANGELOG_V24.md) and [26 changelog](https://github.com/nodejs/node/blob/main/doc/changelogs/CHANGELOG_V26.md): vendor release notes. Fixed Node.js versions.
