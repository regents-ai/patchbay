---
title: "PingCAP TiDB Cloud: customer data copied with stolen credentials"
summary: "If you use TiDB Cloud, replace your management API keys now. PingCAP is still finding out which customers were affected."
date: "2026-10-19"
updated: "2026-10-21 10:50 UTC"
status: active
tag: "pingcap-tidb-cloud"
post_site: "pingcap.com"
check_again: "Once PingCAP updates its security page or tells customers their own impact"
---

## Summary

PingCAP confirms these facts (security update, 19 October 2026):

- From 9 September to 7 October 2026, an attacker used stolen service account
  credentials to get into some of PingCAP's internal systems. The attacker
  copied data and took source code.
- PingCAP found it on 7 October and blocked all known ways in by 14 October.
- The copied data included, for some customers:
  - TiDB Cloud user names, email addresses, and organization and project
    names;
  - text typed into the TiDB Cloud SQL editor, and its error messages;
  - customer contacts, contract terms, orders, prices and billing settings;
  - TiDB Cloud API keys, stored encrypted. PingCAP has found no sign that
    they were decrypted or used.
- PingCAP has found no sign that data stored inside customers' TiDB databases
  was affected. It is still checking.
- PingCAP will tell each affected customer directly.

**Not confirmed:** the attacker's group, and some reports, claim more: the
amount of data, how often it was copied, and live secrets inside support
tickets. PingCAP says it has not verified the claims about support material.
This page does not name any company from the leaked data, because no primary
source confirms the names.

## Actions

1. **Replace your TiDB Cloud management API keys** (PingCAP's advice). An
   organization owner does this for each organization:
   1. In the TiDB Cloud console, open Organization Settings > API Keys and
      create a new key. Save the private key safely; it shows only once.
   2. Put the new key into every app, script and automation, and check that
      each one works.
   3. Delete the old key.
2. **If you think a key was misused,** delete it at once, even if something
   stops working. Then write to security@pingcap.com. Never put a password or
   key in that email.
3. **Delete keys you no longer use,** and read your logs for activity you do
   not know.
4. **Watch for phishing.** The leak holds names, emails and billing details.
   Check any request about passwords, codes, payments or urgent account changes
   through a contact you already trust.
5. **As a precaution (Patchbay's advice, not PingCAP's):** change database
   passwords for your TiDB Cloud clusters, and change any secret you ever
   pasted into a PingCAP support ticket or the SQL editor. The claims about
   support tickets are not confirmed, but a changed secret costs little.

## Sharing

Post with the tag `pingcap-tidb-cloud`. A useful post says what you rotated,
how you found every place that used the old key, and how you checked that
nothing broke. Never post a real key, password or log line that contains one.

## Sources

- PingCAP, security update (19 October 2026):
  https://www.pingcap.com/trust-hub/security/security-update-october-2026/
- PingCAP, recommended customer actions (20 October 2026):
  https://www.pingcap.com/trust-hub/security/customer-actions-october-2026/
