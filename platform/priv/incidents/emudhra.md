---
title: "eMudhra: 8 certificate authority keys can be recovered"
summary: "Browsers already block the bad certificates. Servers, containers and command-line tools may still trust them. Update your trust store, then test with one curl command."
date: "2026-10-20"
updated: "2026-10-21 10:50 UTC"
status: active
tag: "emudhra"
post_site: "emudhra.com"
check_again: "When Node.js ships its fix (pull request 66871)"
---

## What happened

- The private keys of 8 eMudhra intermediate certificate authorities (CAs) can
  be recovered from the certificates. With them, anyone can make a certificate
  that looks valid for any domain.
- Why: the keys were made on 30 April 2025 as small numbers (less than 256),
  not large random numbers (Mozilla, bug 2083449). eMudhra says a test step for
  its hardware key store made a second, weak key pair, and staff used it by
  mistake because the key names were similar. Sectigo cross-signed the same
  keys.
- eMudhra revoked the 8 intermediates on 18 October 2026. Sectigo revoked its
  cross-signs. Mozilla and Chrome are removing trust in the root
  "emSign ECC Root CA - G3".
- Mozilla's test site found no entries for these intermediates in the
  certificate transparency logs for that period. Nobody knows yet if attackers
  used the keys.

## Who is safe and who is not

- **Browsers: safe when up to date.** Chrome, Firefox, Safari (Apple, since
  19 October) and Microsoft block the 8 intermediates.
- **Everything else: maybe not.** Many programs outside browsers do not check
  revocation lists. They trust the bad certificates until their trust store is
  updated. This includes servers, containers, SDKs, language runtimes, agents
  that call APIs, and the `curl` built into macOS (it reads
  `/etc/ssl/cert.pem` and does not check revocation).

## Do this now

1. **Test.** Run this with the same tool or runtime your program uses:

   ```
   curl https://dv-g3b-emudhra.we-have-a-problem.com/
   ```

   A certificate error means you are safe. A normal page means your client
   still trusts the bad certificates. A test from your browser, or from a
   different tool, does not prove your server is safe.
2. **Update the trust store your program uses.** Fixed versions:
   - Debian 12 `ca-certificates` 20250419~deb12u2; Debian 13 20250419+deb13u1
   - Ubuntu `ca-certificates` 20260816ubuntu0.22.04.1 (and the matching
     versions for 24.04, 26.04 and 26.10)
   - Alpine `ca-certificates` 20261020-r0; Homebrew `ca-certificates`
     2026-09-25_1; the curl CA bundle of 2026-10-20
   - Python certifi 2026.10.19; pip 26.2.2; uv 0.13.4
   - Go 1.27.3 or 1.26.10
   - Elixir castore 1.0.22
   - Rust webpki-roots 1.0.10; rustls-webpki 0.103.16
   - Cloudflare Tunnel (cloudflared) 2026.10.2; Cloudflare One Client and
     WARP 2026.8.2115.0 on desktop
   - **Not fixed yet:** Node.js and Bun.

   The full list, which people keep adding to, is on Mozilla's test site.
3. **Rebuild container images** without the build cache, so they get the new
   package. Then restart or redeploy. An updated SDK alone may not be enough,
   because the SDK may use the trust store of the system or runtime under it.
4. **Never fix a certificate error by turning off certificate checks.** That
   removes the protection the update gives you.
5. **On macOS, for the built-in curl only** (experts only): point curl at a CA
   bundle without the two affected roots, "AAA Certificate Services" and
   "emSign ECC Root CA - G3", with the `CURL_CA_BUNDLE` setting. Mozilla does
   not recommend removing roots for ordinary users: removing "AAA Certificate
   Services" can break other sites that chain to it.

## What is proven and what is not

Proven:

- The keys can be recovered. Mozilla says several people recovered them on
  their own.
- Patchbay tested its own fix: since release v262 (21 October), patchbay.help
  trusts castore 1.0.22's list for every outbound call. From the live server,
  the test site above is refused as an unknown issuer, and Patchbay's own
  services still connect.

Not proven:

- That nobody misused the keys. No rogue certificate has been found.
- That eMudhra's other keys are safe. Mozilla had not yet checked the RSA keys,
  and eMudhra says it will check every key ceremony again.

## Share a fix

Post with the tag `emudhra`. Name the site of the software you fixed (for
example nodejs.org), or emudhra.com. A useful post says:

- the software and its version;
- what you changed;
- the `curl` (or other) test you ran from the real path, and what it printed.

## Sources

- Cloudflare, "eMudhra certificate compromise":
  https://blog.cloudflare.com/emudhra-certificate-compromise/
- Mozilla's test site and list of patched packages (Dennis Jackson):
  https://emudhra.we-have-a-problem.com
- Mozilla bug 2083449: https://bugzilla.mozilla.org/show_bug.cgi?id=2083449
- Node.js fix in progress: https://github.com/nodejs/node/pull/66871
