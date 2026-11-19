# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: incidents.spec.ts >> the list leads to a briefing, read signed out
- Location: test/browser/incidents.spec.ts:6:1

# Error details

```
Error: expect(locator).toContainText(expected) failed

Locator: locator('.pb-incident-row').first()
Timeout: 5000ms
- Expected substring  - 1
+ Received string     + 9

- Checked
+
+         CVE-2026-100001: Acme Gateway remote code execution
+         
+           Posted 13 November 2026
+           
+             0 replies
+           
+         
+       

Call log:
  - Expect "toContainText" locator('.pb-incident-row').first() with timeout 5000ms
  - waiting for locator('.pb-incident-row').first()
    14 × locator resolved to <li data-phx-loc="22" class="pb-incident-row">…</li>
       - unexpected value "
        CVE-2026-100001: Acme Gateway remote code execution
        
          Posted 13 November 2026
          
            0 replies
          
        
      "

```

```yaml
- listitem:
  - 'link "CVE-2026-100001: Acme Gateway remote code execution"':
    - /url: /posts/46474487-208a-4a2b-91ef-a2c76cfbabb2/cve-2026-100001-acme-gateway-remote-code-execution
  - paragraph:
    - text: Posted 13 November 2026
    - link "0 replies":
      - /url: /posts/46474487-208a-4a2b-91ef-a2c76cfbabb2/cve-2026-100001-acme-gateway-remote-code-execution#patchbay-replies
```

# Test source

```ts
  1  | import {expect, signedIn, test, watch} from "./support/test"
  2  | 
  3  | // An incident's page is one discussion: the list leads to it, the briefing opens
  4  | // it, and the reply form sits right under it.
  5  | 
  6  | test("the list leads to a briefing, read signed out", async ({page}) => {
  7  |   const problems = watch(page)
  8  |   await page.goto("/incidents")
  9  |   await expect(page.locator(".pb-incident-row").first()).toBeVisible()
> 10 |   await expect(page.locator(".pb-incident-row").first()).toContainText("Checked")
     |                                                          ^ Error: expect(locator).toContainText(expected) failed
  11 |   await expect(page.locator(".pb-incident-row").first()).toContainText(/\d+ repl/)
  12 | 
  13 |   await page.locator(".pb-incident-row-title").first().click()
  14 |   await expect(page).toHaveURL(/\/incidents\/[a-z0-9-]+$/)
  15 |   await expect(page.locator("#pb-post")).toContainText("Summary")
  16 |   await expect(page.locator("#pb-post")).toContainText("Actions")
  17 |   await expect(page.locator(".pb-thread-back")).toHaveAttribute("href", "/incidents")
  18 |   await expect(page.locator("#report-evidence")).toHaveCount(0)
  19 | 
  20 |   await problems.expect()
  21 | })
  22 | 
  23 | test("a critical CVE copied from cve.now leads to its post", async ({page}) => {
  24 |   const problems = watch(page)
  25 |   await page.goto("/incidents")
  26 |   const row = page.locator("#patchbay-cves .pb-incident-row").first()
  27 |   await expect(row).toContainText("CVE-2026-100001")
  28 |   await expect(row).toContainText(/\d+ repl/)
  29 | 
  30 |   await row.locator(".pb-incident-row-title").click()
  31 |   await expect(page).toHaveURL(/\/posts\/[0-9a-f-]+\/cve-2026-100001/)
  32 |   await expect(page.locator("#pb-post")).toContainText("Acme Gateway lets an attacker run code")
  33 |   await expect(page.locator("#pb-post").getByRole("link", {name: "cve.now/CVE-2026-100001"})).toHaveAttribute(
  34 |     "href",
  35 |     "https://cve.now/CVE-2026-100001",
  36 |   )
  37 | 
  38 |   await problems.expect()
  39 | })
  40 | 
  41 | test.describe("signed in", () => {
  42 |   test.use(signedIn)
  43 | 
  44 |   // Posting takes a check against an outside service the walk has no reach of, so
  45 |   // this stops at the form; test/patchbay_web/controllers/incident_controller_test.exs
  46 |   // posts one.
  47 |   test("the reply form sits under the briefing", async ({page}) => {
  48 |     const problems = watch(page)
  49 |     await page.goto("/incidents/emudhra")
  50 |     await expect(page.locator("#patchbay-replies").getByRole("textbox", {name: "Your reply"})).toBeVisible()
  51 |     await expect(page.locator("#patchbay-replies").getByRole("button", {name: "Post reply"})).toBeVisible()
  52 |     await problems.expect()
  53 |   })
  54 | })
  55 | 
```