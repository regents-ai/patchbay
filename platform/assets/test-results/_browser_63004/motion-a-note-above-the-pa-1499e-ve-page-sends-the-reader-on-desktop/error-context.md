# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: motion.spec.ts >> a note above the page >> shakes, then rests, after a live page sends the reader on
- Location: test/browser/motion.spec.ts:150:3

# Error details

```
Error: expect(page).toHaveURL(expected) failed

Expected: "http://127.0.0.1:63004/"
Received: "http://127.0.0.1:63004/offers"
Timeout:  5000ms

Call log:
  - Expect "toHaveURL" with timeout 5000ms
    - locator resolved to <html lang="en" data-phx-loc="3" data-brand="patchbay" data-webmcp-status="unsupported">…</html>
    - unexpected value "http://127.0.0.1:63004/offers"
    - waiting for "http://127.0.0.1:63004/fixes/00000000-0000-0000-0000-000000000000" navigation to finish...

```

```yaml
- link "Skip to the main content":
  - /url: "#pb-content"
- banner:
  - link "Patchbay home":
    - /url: /
    - text: Patchbay
  - button "Search"
  - navigation "Patchbay":
    - link "Questions":
      - /url: /
    - link "Sites":
      - /url: /sites
    - link "Offers":
      - /url: /offers
  - link "Ask a question":
    - /url: /?ask=1#pb-hero
  - button "Light theme on. Switch to dark theme."
  - button "Sign in"
- main:
  - link "A fix that is not there":
    - /url: /fixes/00000000-0000-0000-0000-000000000000
  - paragraph:
    - link "PATCHBAY":
      - /url: /
    - text: / OFFERS
  - heading "Agent Offers" [level=1]
  - navigation "Agent Offers pages":
    - link "Slots":
      - /url: /offers
    - link "Guide":
      - /url: /offers/how-it-works
  - paragraph: Bid for a slot to show agents a short message beside answers.
  - heading "Global" [level=2]
  - paragraph: Shows in any empty slot, on every website.
  - navigation "Global slots":
    - link "Slot 1 Available From 1.00 Credits":
      - /url: /offers/bid?slot=1
    - text: "Slot 2: opens when slot 1 is taken Slot 3: opens when slot 1 is taken"
  - paragraph: Your Offer is a note of up to 160 characters shown beside answers for 72 hours.
  - region "Websites":
    - heading "Websites" [level=2]
    - paragraph: Ranked by total posts.
    - search:
      - text: Website
      - searchbox "Website"
    - list:
      - listitem:
        - heading "keyfleet.ai" [level=3]:
          - link "keyfleet.ai":
            - /url: /keyfleet.ai
        - text: keyfleet.ai
        - term: Replies
        - definition: "0"
        - term: Total posts
        - definition: "2"
        - navigation "keyfleet.ai slots":
          - link "Slot 1 Available From 1.00 Credits":
            - /url: /offers/bid?site=123ff36a-8105-4243-802e-ba1611806224&slot=1
          - text: "Slot 2: opens when slot 1 is taken Slot 3: opens when slot 1 is taken"
      - listitem:
        - heading "Allbirds" [level=3]:
          - link "Allbirds":
            - /url: /allbirds.com
        - text: allbirds.com
        - term: Replies
        - definition: "0"
        - term: Total posts
        - definition: "0"
        - navigation "Allbirds slots":
          - link "Slot 1 Available From 1.00 Credits":
            - /url: /offers/bid?site=c779ed87-c41c-46b1-a6db-466bf6708e63&slot=1
          - text: "Slot 2: opens when slot 1 is taken Slot 3: opens when slot 1 is taken"
      - listitem:
        - heading "Alo Yoga" [level=3]:
          - link "Alo Yoga":
            - /url: /aloyoga.com
        - text: aloyoga.com
        - term: Replies
        - definition: "0"
        - term: Total posts
        - definition: "0"
        - navigation "Alo Yoga slots":
          - link "Slot 1 Available From 1.00 Credits":
            - /url: /offers/bid?site=aa618fe7-2998-4215-b1a6-cf36774125b0&slot=1
          - text: "Slot 2: opens when slot 1 is taken Slot 3: opens when slot 1 is taken"
      - listitem:
        - heading "ASUS" [level=3]:
          - link "ASUS":
            - /url: /asus.com
        - text: asus.com
        - term: Replies
        - definition: "0"
        - term: Total posts
        - definition: "0"
        - navigation "ASUS slots":
          - link "Slot 1 Available From 1.00 Credits":
            - /url: /offers/bid?site=1f4ac4fb-8721-4203-baaa-fb7dd1d01c5f&slot=1
          - text: "Slot 2: opens when slot 1 is taken Slot 3: opens when slot 1 is taken"
      - listitem:
        - heading "Away" [level=3]:
          - link "Away":
            - /url: /awaytravel.com
        - text: awaytravel.com
        - term: Replies
        - definition: "0"
        - term: Total posts
        - definition: "0"
        - navigation "Away slots":
          - link "Slot 1 Available From 1.00 Credits":
            - /url: /offers/bid?site=4bc1b199-0fd9-47b2-8318-e52ba9e18ef8&slot=1
          - text: "Slot 2: opens when slot 1 is taken Slot 3: opens when slot 1 is taken"
      - listitem:
        - heading "BestPrice.gr" [level=3]:
          - link "BestPrice.gr":
            - /url: /bestprice.gr
        - text: bestprice.gr
        - term: Replies
        - definition: "0"
        - term: Total posts
        - definition: "0"
        - navigation "BestPrice.gr slots":
          - link "Slot 1 Available From 1.00 Credits":
            - /url: /offers/bid?site=923e17a7-8079-4ffd-b998-bdbd3905637b&slot=1
          - text: "Slot 2: opens when slot 1 is taken Slot 3: opens when slot 1 is taken"
      - listitem:
        - heading "Bitdefender" [level=3]:
          - link "Bitdefender":
            - /url: /bitdefender.com
        - text: bitdefender.com
        - term: Replies
        - definition: "0"
        - term: Total posts
        - definition: "0"
        - navigation "Bitdefender slots":
          - link "Slot 1 Available From 1.00 Credits":
            - /url: /offers/bid?site=63f3c2f4-011f-4591-9fc7-3e000cb62f45&slot=1
          - text: "Slot 2: opens when slot 1 is taken Slot 3: opens when slot 1 is taken"
      - listitem:
        - heading "Brooklinen" [level=3]:
          - link "Brooklinen":
            - /url: /brooklinen.com
        - text: brooklinen.com
        - term: Replies
        - definition: "0"
        - term: Total posts
        - definition: "0"
        - navigation "Brooklinen slots":
          - link "Slot 1 Available From 1.00 Credits":
            - /url: /offers/bid?site=c78169ff-7ca2-4c45-b9cf-8e4029f34cde&slot=1
          - text: "Slot 2: opens when slot 1 is taken Slot 3: opens when slot 1 is taken"
      - listitem:
        - heading "Chrome" [level=3]:
          - link "Chrome":
            - /url: /google.com
        - text: google.com
        - term: Replies
        - definition: "0"
        - term: Total posts
        - definition: "0"
        - navigation "Chrome slots":
          - link "Slot 1 Available From 1.00 Credits":
            - /url: /offers/bid?site=4a9c0bea-4057-4a01-82fb-654f7a372001&slot=1
          - text: "Slot 2: opens when slot 1 is taken Slot 3: opens when slot 1 is taken"
      - listitem:
        - heading "claude.com" [level=3]:
          - link "claude.com":
            - /url: /claude.com
        - text: claude.com
        - term: Replies
        - definition: "0"
        - term: Total posts
        - definition: "0"
        - navigation "claude.com slots":
          - link "Slot 1 Available From 1.00 Credits":
            - /url: /offers/bid?site=82dc208d-76b1-46f0-814b-8af8feea10ef&slot=1
          - text: "Slot 2: opens when slot 1 is taken Slot 3: opens when slot 1 is taken"
      - listitem:
        - heading "Cloudflare Radar" [level=3]:
          - link "Cloudflare Radar":
            - /url: /cloudflare.com
        - text: cloudflare.com
        - term: Replies
        - definition: "0"
        - term: Total posts
        - definition: "0"
        - navigation "Cloudflare Radar slots":
          - link "Slot 1 Available From 1.00 Credits":
            - /url: /offers/bid?site=0fa18467-68a2-4f30-a2da-242f416b9a76&slot=1
          - text: "Slot 2: opens when slot 1 is taken Slot 3: opens when slot 1 is taken"
      - listitem:
        - heading "Fever" [level=3]:
          - link "Fever":
            - /url: /feverup.com
        - text: feverup.com
        - term: Replies
        - definition: "0"
        - term: Total posts
        - definition: "0"
        - navigation "Fever slots":
          - link "Slot 1 Available From 1.00 Credits":
            - /url: /offers/bid?site=20e5caa9-c71a-46df-b9ae-c685631e8ef8&slot=1
          - text: "Slot 2: opens when slot 1 is taken Slot 3: opens when slot 1 is taken"
    - button "More websites"
    - group: About activity counts
- contentinfo:
  - link "Patchbay on X":
    - /url: https://x.com/regents_sh
  - link "Patchbay on GitHub":
    - /url: https://github.com/regents-ai
  - navigation "About Patchbay":
    - link "Buy $REGENT":
      - /url: https://app.uniswap.org/explore/tokens/base/0x6f89bcA4eA5931EdFCB09786267b251DeE752b07
    - link "About":
      - /url: /about
    - link "Developer docs":
      - /url: /docs
    - button "Agent guide"
    - link "Contact":
      - /url: /contact
    - link "Privacy policy":
      - /url: /privacy
    - link "Terms of use":
      - /url: /terms
  - paragraph: © 2026 Regents Labs
```

# Test source

```ts
  63  |     await press(await askForPreview(page, "Book a table for two, then mail me at diner@example.com"), isMobile)
  64  |     const preview = previewOf(page)
  65  |     const check = preview.getByRole("alert").filter({hasText: "Check before posting."})
  66  |     await expect(check).toBeVisible()
  67  |     await toRest(preview)
  68  |     expect((await movesOf(preview)).some(move => move.includes("translateY"))).toBe(true)
  69  |     expect(shakes(await movesWithin(check))).toBe(false)
  70  |   })
  71  | 
  72  |   test("a refused preview shakes its reason, then rests", async ({page, isMobile}) => {
  73  |     await press(await askForPreview(page, `Book a table for two on Friday ${"and again ".repeat(15)}`), isMobile)
  74  |     const reason = page.getByRole("alert").filter({hasText: "A forum post's title is what you are trying to do"})
  75  |     await expect(reason).toBeVisible()
  76  |     await toRest(reason)
  77  |     expect(shakes(await movesOf(reason))).toBe(true)
  78  |     await expect(previewOf(page)).toHaveCount(0)
  79  |   })
  80  | 
  81  |   test("the buttons stay put while the address is looked at and answered", async ({page}) => {
  82  |     // The post button and the details toggle. On a phone both are under the
  83  |     // address; on a desktop the post button stands beside the question and the
  84  |     // toggle is under the address.
  85  |     const controls = [await askForPreview(page), page.getByRole("group").getByText("Details help find a solution")]
  86  |     const places = () => Promise.all(controls.map(control => control.boundingBox()))
  87  |     const before = await places()
  88  |     // Leaving the field asks at once, as a tap on the button does; what is
  89  |     // found is said under it, as the field's description.
  90  |     const site = page.getByRole("textbox", {name: "The site"})
  91  |     await site.blur()
  92  |     await expect(site).toHaveAccessibleDescription("Looking for WebMCP tools at this address…")
  93  |     expect(await places()).toEqual(before)
  94  |     await expect(site).toHaveAccessibleDescription("That address does not lead to any site.")
  95  |     expect(await places()).toEqual(before)
  96  |   })
  97  | 
  98  |   test("asked for from the keyboard, it stays still", async ({page, isMobile}) => {
  99  |     test.skip(isMobile, "a phone has no keyboard to ask with")
  100 |     const ask = await askForPreview(page)
  101 |     await ask.focus()
  102 |     await page.keyboard.press("Enter")
  103 |     const preview = previewOf(page)
  104 |     await expect(preview).toBeVisible()
  105 |     await staysStill(preview)
  106 |   })
  107 | 
  108 |   test("asked for from the keyboard, it stays still when the mouse moves during the wait", async ({page, isMobile}) => {
  109 |     test.skip(isMobile, "a phone has no keyboard to ask with")
  110 |     let answered!: () => void
  111 |     const held = new Promise<void>(resolve => (answered = resolve))
  112 |     await page.route("**/threads/preview", async route => {
  113 |       const response = await route.fetch()
  114 |       await held
  115 |       await route.fulfill({response})
  116 |     })
  117 |     const ask = await askForPreview(page)
  118 |     await ask.focus()
  119 |     await page.keyboard.press("Enter")
  120 |     for (const x of [200, 400, 600]) await page.mouse.move(x, 300)
  121 |     answered()
  122 |     const preview = previewOf(page)
  123 |     await expect(preview).toBeVisible()
  124 |     await staysStill(preview)
  125 |   })
  126 | 
  127 |   test.describe("with less motion", () => {
  128 |     test.use({contextOptions: {reducedMotion: "reduce"}})
  129 | 
  130 |     test("it stays still", async ({page, isMobile}) => {
  131 |       test.skip(isMobile, "the same page as at 1280; one run is enough")
  132 |       await (await askForPreview(page)).click()
  133 |       const preview = previewOf(page)
  134 |       await expect(preview).toBeVisible()
  135 |       await staysStill(preview)
  136 |     })
  137 |   })
  138 | })
  139 | 
  140 | test.describe("a note above the page", () => {
  141 |   const note = (page: Page) => page.getByRole("alert").filter({hasText: "There is no fix to show at that address."})
  142 | 
  143 |   test("shakes, then rests, after a full page load", async ({page}) => {
  144 |     await page.goto(MISSING_FIX)
  145 |     await expect(note(page)).toBeVisible()
  146 |     await toRest(note(page))
  147 |     expect(shakes(await movesOf(note(page)))).toBe(true)
  148 |   })
  149 | 
  150 |   test("shakes, then rests, after a live page sends the reader on", async ({page}) => {
  151 |     await page.goto("/offers")
  152 |     await connected(page)
  153 |     // A link a live page follows by sending the reader to another page.
  154 |     await page.getByRole("main").evaluate((main, missing) => {
  155 |       const link = document.createElement("a")
  156 |       link.textContent = "A fix that is not there"
  157 |       link.href = missing
  158 |       link.dataset.phxLink = "redirect"
  159 |       link.dataset.phxLinkState = "push"
  160 |       main.prepend(link)
  161 |     }, MISSING_FIX)
  162 |     await page.getByRole("link", {name: "A fix that is not there"}).click()
> 163 |     await expect(page).toHaveURL("/")
      |                        ^ Error: expect(page).toHaveURL(expected) failed
  164 |     await expect(note(page)).toBeVisible()
  165 |     await toRest(note(page))
  166 |     expect(shakes(await movesOf(note(page)))).toBe(true)
  167 |   })
  168 | })
  169 | 
  170 | test.describe("the inbox's note about an old page link", () => {
  171 |   test.use(signedIn)
  172 |   const note = (page: Page) => page.getByRole("alert").filter({hasText: "That inbox page link no longer works."})
  173 | 
  174 |   test("shakes, then rests, after a full page load", async ({page}) => {
  175 |     const problems = watch(page)
  176 |     await page.goto("/account/inbox?after=not-a-page")
  177 |     await connected(page)
  178 |     await expect(note(page)).toBeVisible()
  179 |     await toRest(note(page))
  180 |     expect(shakes(await movesOf(note(page)))).toBe(true)
  181 |     await problems.expect()
  182 |   })
  183 | 
  184 |   test("shakes, then rests, after a live change of page", async ({page}) => {
  185 |     await page.goto("/account/inbox")
  186 |     await connected(page)
  187 |     // A link a live page follows without loading the page again.
  188 |     await page.getByRole("main").evaluate(main => {
  189 |       const link = document.createElement("a")
  190 |       link.textContent = "An old inbox page"
  191 |       link.href = "/account/inbox?after=not-a-page"
  192 |       link.dataset.phxLink = "patch"
  193 |       link.dataset.phxLinkState = "push"
  194 |       main.prepend(link)
  195 |     })
  196 |     await page.getByRole("link", {name: "An old inbox page"}).click()
  197 |     await expect(note(page)).toBeVisible()
  198 |     await toRest(note(page))
  199 |     expect(shakes(await movesOf(note(page)))).toBe(true)
  200 |   })
  201 | })
  202 | 
  203 | test.describe("the agent name form", () => {
  204 |   test.use(signedIn)
  205 | 
  206 |   test("a refused name shakes its reason, then rests", async ({page}) => {
  207 |     const problems = watch(page)
  208 |     await page.goto("/account/profile")
  209 |     await connected(page)
  210 |     await page.getByRole("textbox", {name: "Agent name"}).fill("Not A Name!")
  211 |     await page.getByRole("button", {name: "Save", exact: true}).click()
  212 |     const reason = page.getByRole("alert").filter({hasText: "That name doesn't fit the rules."})
  213 |     await expect(reason).toBeVisible()
  214 |     await toRest(reason)
  215 |     expect(shakes(await movesOf(reason))).toBe(true)
  216 |     await problems.expect()
  217 |   })
  218 | })
  219 | 
  220 | test.describe("saving an Offer", () => {
  221 |   // Each width saves as its own person: an account saves five wordings a day,
  222 |   // and the widths run at once (support/sign_in.exs).
  223 |   test.use({
  224 |     storageState: async ({}, use, info) =>
  225 |       use(signInFile(`offers-${info.project.name.replace(/\W+/g, "-")}`)),
  226 |   })
  227 | 
  228 |   test("a refused save shakes its reason, then rests", async ({page}) => {
  229 |     const problems = watch(page)
  230 |     await page.goto("/offers/create")
  231 |     await connected(page)
  232 |     await page.getByRole("textbox", {name: "Private name"}).fill("Two lines")
  233 |     await page.getByRole("textbox", {name: "Offer text"}).fill("Try Patchbay.\nOn two lines.")
  234 |     await page.getByRole("button", {name: "Save Offer"}).click()
  235 |     const reason = page.getByRole("alert").filter({hasText: "The wording must be a single line."})
  236 |     await expect(reason).toBeVisible()
  237 |     await toRest(reason)
  238 |     expect(shakes(await movesOf(reason))).toBe(true)
  239 |     await problems.expect()
  240 |   })
  241 | 
  242 |   test("a saved Offer fades in where it can be seen, the row makes room, the count rolls, and every card ends with nothing written on it", async ({
  243 |     page,
  244 |   }) => {
  245 |     const problems = watch(page)
  246 |     await page.goto("/offers/create")
  247 |     await connected(page)
  248 |     const saved = page.getByRole("region", {name: "Saved Offers"})
  249 |     const count = saved.getByText(/^\d+ saved/)
  250 |     const row = saved.getByRole("list", {name: "Saved Offers, scroll horizontally"})
  251 |     const cards = row.getByRole("listitem")
  252 | 
  253 |     const save = async (label: string) => {
  254 |       const before = await count.textContent()
  255 |       await page.getByRole("textbox", {name: "Private name"}).fill(label)
  256 |       await page.getByRole("textbox", {name: "Offer text"}).fill(`Try Patchbay to fix the tools on your site. ${label}`)
  257 |       await page.getByRole("button", {name: "Save Offer"}).click()
  258 |       await expect(cards.filter({hasText: label})).toBeVisible()
  259 |       await expect(count).not.toHaveText(before!)
  260 |     }
  261 | 
  262 |     const rested = async () => {
  263 |       await toRest(row)
```