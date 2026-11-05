---
title: "PingCAP TiDB Cloud: customer data copied with stolen credentials"
summary: "Replace your TiDB Cloud management API keys and rotate anything you shared with PingCAP support. PingCAP is still working out each customer's impact."
date: "2026-10-19"
checked: "2026-11-05"
status: active
tag: "pingcap-tidb-cloud"
post_site: "pingcap.com"
check_again: "When PingCAP updates its incident report or tells customers their own impact"
---

## Summary

- From 9 September to 7 October 2026, an attacker got into PingCAP's internal systems through a compromised GitHub account and credentials left exposed. PingCAP disclosed this on 19 October.
- The attacker took source code and copied records from internal analytics, storage and support systems, including customer information.
- PingCAP found the activity on 7 October. By 14 October, it says, all identified stolen credentials were invalid and known ways in were blocked.
- PingCAP hired NebuSec to investigate. NebuSec published its report on 21 October, and PingCAP's CEO wrote to customers on 23 October.

## Exposure

Copied data, per PingCAP and NebuSec. Scope varies by customer:

- Source code, configuration files and credentials from private GitHub repositories.
- Account and organization records, cluster and connection configuration, and encrypted API-key values.
- SQL editor history, AI interactions and gateway connection logs.
- Customer contacts, contracts, orders, pricing and billing details.
- Support tickets, attachments, logs and SQL files, including credentials customers had shared. These included AWS keys, and some of those keys reached S3 buckets holding a customer's TiDB diagnostic data.
- In Japan, PingCAP's notice says up to about 50,000 personal records.

Findings so far:

- NebuSec reports no sign of access to data inside customer TiDB databases, and no attacker foothold left in production. This rests on the logs and evidence available, and PingCAP hired NebuSec.
- TiDB Cloud API-key values in the exported table were stored encrypted, and the key to decrypt them stayed safe. NebuSec could not decrypt them. This does not cover credentials in support material.
- NebuSec reported four flaws in the affected services. PingCAP fixed them, and a log review found no evidence they had been used.

**Exploitation:** PingCAP confirmed the intrusion on 19 October 2026. It came from stolen credentials, not a published software flaw. Press reports repeat attacker claims about larger amounts of data and plaintext keys. No primary source we opened confirms those numbers, so we do not repeat them as fact. We do not name any company from the leaked data.

## Actions

1. Replace your TiDB Cloud management API keys now. An organization owner does this for each organization, and PingCAP says not to wait for a direct notice.
   - In the console, open Organization Settings, then API Keys, then Create API Key.
   - Save the public and private key. The private key shows once.
   - Put the new key into each app and script, and check that each one works.
   - Delete the old key from its row's "…" menu.
2. If you suspect a key was misused, revoke it at once, even if something stops working. Then write to security@pingcap.com. Never put a password, token or key in that email.
3. Delete keys you no longer need.
4. Rotate anything you ever shared with PingCAP support: credentials, keys, connection strings, and logs that contain secrets. Check AWS keys first, because NebuSec found these were used.
5. Ask PingCAP for an assessment of your organization. Its CEO note invites this, and scope varies by customer.
6. Review your access logs, organization members and roles. PingCAP's Japanese notice asks for this. Customers in Japan can write to security-jp@pingcap.com.
7. Watch for targeted phishing. Check any request about passwords, codes or payment changes through a contact you already trust.
8. As our own precaution, not PingCAP's advice, change any secret you typed into the SQL editor and the database passwords for clusters whose connection details you are unsure of. SQL editor history and connection configuration were among the copied data.

## Sources

- [PingCAP security update, 19 October 2026](https://www.pingcap.com/trust-hub/security/security-update-october-2026/): vendor report. Dates, data categories, containment, direct notices.
- [PingCAP customer actions, 20 October 2026](https://www.pingcap.com/trust-hub/security/customer-actions-october-2026/): vendor guidance. Key rotation steps, misuse advice, phishing.
- [PingCAP CEO note, 23 October 2026](https://www.pingcap.com/trust-hub/security/ceo-note-october-2026/): vendor statement. GitHub account, support material rotation, assessment offer.
- [NebuSec report, 21 October 2026](https://nebusec.ai/research/pingcap-security-incident/): research commissioned by PingCAP. Data by source, AWS keys in tickets, encrypted keys, no database access found, four flaws.
- [PingCAP notice for Japan](https://pingcap.co.jp/trust-hub/security/security-update-october-2026/): vendor report. About 50,000 records, log and role review, Japan contact.
