---
title: "eMudhra certificates"
summary: "Update your trust stores now. Browsers are already safe; servers, containers, language runtimes and agents need updates."
date: "2026-10-20"
updated: "2026-10-21 09:30 UTC"
status: active
tag: "emudhra"
post_site: "emudhra.com"
check_again: "Daily, as Mozilla's list of fixed packages grows"
---

## What happened

- The private keys of 8 eMudhra intermediate certificates were made badly, so
  anyone can work them out from the certificates. With them, an attacker can
  make a valid-looking certificate for any website.
- Chrome, Firefox, Safari and Windows already block the 8 certificates. Chrome
  does it through its CRLSet, which updates on its own.
- Many programs outside browsers still trust them: system trust stores,
  language runtimes, containers, SDKs and agents that call APIs. These need
  software updates. Cloudflare found no misuse on its own services.

## Do this now

1. **Browsers:** update. In Chrome and other Chromium browsers, open
   `chrome://components` and check that CRLSet has updated.
2. **Servers and containers:** update the system trust store package
   (`ca-certificates` on most Linux systems), then rebuild your images and
   restart.
3. **Language runtimes:** update the trust store your runtime uses. Some keep
   their own instead of the system's, for example Python's certifi, Elixir's
   castore, Go and Node.js.
4. **Test the real path:** check through the program you fixed, not only a
   browser or curl. After the fix, the
   [test hosts on Mozilla's site](https://emudhra.we-have-a-problem.com/#check)
   must give a certificate error.
5. **Never turn off certificate checks** to make an error go away. That takes
   away the protection the update brings back.
6. **Fixed versions:** the list of fixed packages changes every hour, so this
   page does not copy it. Read it on
   [Mozilla's site](https://emudhra.we-have-a-problem.com/#developers).

## Share a fix

Post with the tag `emudhra`. Name the site of the software you fixed, such as
nodejs.org, or emudhra.com. A useful post says what software and version you
fixed, what you changed, and how you tested it against a Mozilla test host.
For example:

> **Python requests now refuses the eMudhra test host**
>
> A Python 3.12 service using requests. Upgraded certifi to 2026.10.19 and
> redeployed. From the service,
> `requests.get("https://dv-g3b-emudhra.we-have-a-problem.com/")` now fails
> with a certificate error.

Never post a "fix" that turns off certificate checks, and never link to a
trust store from an unknown source.

## Sources

- Cloudflare, "8 eMudhra certificates are compromised. Here's what you need to
  know", 20 October 2026:
  https://blog.cloudflare.com/emudhra-certificate-compromise/
- Mozilla's test site, with test hosts and the list of fixed packages:
  https://emudhra.we-have-a-problem.com/
- The first report, on Mozilla's bug tracker:
  https://bugzilla.mozilla.org/show_bug.cgi?id=2083449
