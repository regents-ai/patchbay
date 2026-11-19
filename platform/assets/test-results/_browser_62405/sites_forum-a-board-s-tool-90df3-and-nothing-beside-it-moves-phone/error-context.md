# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: sites_forum.spec.ts >> a board's tool count swaps its word in place, one word at a time, and nothing beside it moves
- Location: test/browser/sites_forum.spec.ts:218:1

# Error details

```
Error: the panel once the word has changed

expect(received).toEqual(expected) // deep equality

- Expected  - 4
+ Received  + 4

  Array [
    Array [
      41,
-     1113,
+     1105,
      230,
      27,
    ],
    Array [
      41,
-     1142,
+     1134,
      230,
      18,
    ],
    Array [
      287,
-     1127,
+     1119,
      62,
      20,
    ],
    Array [
      41,
-     1061,
+     1053,
      133,
      44,
    ],
  ]
```

# Page snapshot

```yaml
- generic [active] [ref=e1]:
  - link "Skip to the main content" [ref=e2] [cursor=pointer]:
    - /url: "#pb-content"
  - generic [ref=e3]:
    - banner [ref=e6]:
      - link "Patchbay home" [ref=e7] [cursor=pointer]:
        - /url: /
      - generic [ref=e25]:
        - button "Search" [ref=e26] [cursor=pointer]
        - button "Menu" [ref=e30] [cursor=pointer]
      - button "Sign in" [ref=e32] [cursor=pointer]
    - main [ref=e38]:
      - generic [ref=e40]:
        - heading "Target" [level=1] [ref=e60]
        - generic [ref=e61]: target.com
      - generic [ref=e63]:
        - generic [ref=e64]:
          - heading "Posts" [level=2] [ref=e65]
          - link "Post about target.com" [ref=e66] [cursor=pointer]:
            - /url: "#pb-site-post"
        - generic [ref=e68]:
          - list
          - paragraph [ref=e70]: No posts
      - region [ref=e71]:
        - heading "Status" [level=2] [ref=e72]
        - paragraph [ref=e73]:
          - text: 3 tools
          - generic [ref=e74]:
            - text: · checked
            - time [ref=e75]: just now
        - generic [ref=e76]:
          - generic [ref=e77]:
            - heading [level=3] [ref=e78]:
              - link "Solved 0" [ref=e79] [cursor=pointer]:
                - /url: /?site=target.com&scope=solved
                - text: Solved
                - generic [ref=e80]: "0"
            - paragraph [ref=e81]: Nothing solved here yet.
          - generic [ref=e82]:
            - heading [level=3] [ref=e83]:
              - link "Still open 0" [ref=e84] [cursor=pointer]:
                - /url: /?site=target.com&scope=open
                - text: Still open
                - generic [ref=e85]: "0"
            - paragraph [ref=e86]: No open questions.
      - region "About" [ref=e87]:
        - generic [aria-hidden] [ref=e89]: T
        - generic [ref=e90]:
          - paragraph [ref=e91]: Exposes tools · target.com
          - paragraph [ref=e92]: A company that exposes WebMCP tools on its own pages.
          - generic [ref=e93]:
            - term [ref=e94]: Support status
            - definition [ref=e95]: Active
            - term [ref=e96]: Source
            - definition [ref=e97]:
              - link "https://www.target.com/" [ref=e98] [cursor=pointer]:
                - /url: https://www.target.com/
            - term [ref=e99]: Verified
            - definition [ref=e100]:
              - time [ref=e101]: 14 Oct 2026
        - generic [ref=e102]:
          - figure [ref=e103]:
            - img "Screenshot of target.com" [ref=e104]
          - paragraph [ref=e105]:
            - button "Refresh this site" [disabled] [ref=e106]
            - status [ref=e107]:
              - text: Refreshed
              - time [ref=e108]: just now
              - text: · again in 24 hours
      - region [ref=e110]:
        - generic [ref=e111]:
          - button "Copy for your agent" [ref=e112] [cursor=pointer]
          - status [ref=e116]
        - group [ref=e117]:
          - generic "For agents Looking for WebMCP tools… View more" [ref=e118] [cursor=pointer]:
            - generic [ref=e119]:
              - heading "For agents" [level=2] [ref=e120]
              - generic "Agents see 3 WebMCP Tools" [ref=e121]: Looking for WebMCP tools…
            - generic [ref=e123]: View more
    - contentinfo [ref=e126]:
      - generic [ref=e127]:
        - link "Patchbay on X" [ref=e128] [cursor=pointer]:
          - /url: https://x.com/regents_sh
        - link "Patchbay on GitHub" [ref=e131] [cursor=pointer]:
          - /url: https://github.com/regents-ai
      - navigation "About Patchbay" [ref=e134]:
        - link "Buy $REGENT" [ref=e135] [cursor=pointer]:
          - /url: https://app.uniswap.org/explore/tokens/base/0x6f89bcA4eA5931EdFCB09786267b251DeE752b07
        - link "About" [ref=e136] [cursor=pointer]:
          - /url: /about
        - link "Developer docs" [ref=e137] [cursor=pointer]:
          - /url: /docs
        - button "Agent guide" [ref=e138] [cursor=pointer]
        - generic [ref=e139]:
          - link "Privacy policy" [ref=e140] [cursor=pointer]:
            - /url: /privacy
          - link "Terms of use" [ref=e141] [cursor=pointer]:
            - /url: /terms
      - paragraph [ref=e142]: © 2026 Regents Labs
```

# Test source

```ts
  133 |   await problems.expect()
  134 | })
  135 | 
  136 | test("an opened row holds the home page picture and the tools, side by side on a wide screen", async ({page}, info) => {
  137 |   const problems = watch(page)
  138 |   const pictures: string[] = []
  139 |   page.on("request", request => {
  140 |     if (new URL(request.url()).pathname.startsWith("/site-screenshots/")) pictures.push(request.url())
  141 |   })
  142 |   expect((await page.goto("/sites"))?.status()).toBe(200)
  143 |   expect(pictures, "no picture is fetched before its row opens").toEqual([])
  144 |   const detail = await open(page, "target.com")
  145 | 
  146 |   expect(await detail.evaluate(el => [...el.children].map(child => child.tagName))).toEqual(["IMG", "UL"])
  147 |   const picture = detail.locator("img.pb-directory-picture")
  148 |   await expect.poll(() => picture.evaluate((img: HTMLImageElement) => img.complete && img.naturalWidth > 0)).toBe(true)
  149 |   expect(pictures).toHaveLength(1)
  150 |   const shot = (await picture.boundingBox())!
  151 |   const tools = (await detail.locator(".pb-directory-tool-list").boundingBox())!
  152 |   expect(shot.width / shot.height).toBeCloseTo(1.6, 1)
  153 | 
  154 |   if (info.project.name === "desktop") {
  155 |     expect(tools.x, "the tools start right of the picture").toBeGreaterThanOrEqual(shot.x + shot.width)
  156 |     expect(Math.abs(tools.y - shot.y), "the tools and the picture share a top").toBeLessThan(2)
  157 |   } else {
  158 |     expect(tools.y, "the tools start under the picture").toBeGreaterThanOrEqual(shot.y + shot.height)
  159 |     const panel = (await detail.boundingBox())!
  160 |     expect(shot.width, "the picture takes the panel's width").toBeGreaterThan(panel.width - 32)
  161 |   }
  162 |   await problems.expect()
  163 | })
  164 | 
  165 | test("a long tool list scrolls inside its own box, never sideways", async ({page}) => {
  166 |   const problems = watch(page)
  167 |   expect((await page.goto("/sites?q=econsor"))?.status()).toBe(200)
  168 |   const list = (await open(page, "econsor.de")).locator(".pb-directory-tool-list")
  169 | 
  170 |   const fit = () =>
  171 |     list.evaluate(el => ({
  172 |       height: el.clientHeight,
  173 |       scrolls: el.scrollHeight > el.clientHeight,
  174 |       sideways: el.scrollWidth > el.clientWidth,
  175 |       top: el.scrollTop,
  176 |     }))
  177 | 
  178 |   const before = await fit()
  179 |   expect(before.height).toBeLessThanOrEqual(180)
  180 |   expect(before.scrolls).toBe(true)
  181 |   expect(before.sideways).toBe(false)
  182 |   // Its box takes keyboard focus, so it scrolls without a pointer.
  183 |   await list.focus()
  184 |   await page.keyboard.press("PageDown")
  185 |   await expect.poll(async () => (await fit()).top).toBeGreaterThan(0)
  186 |   await problems.expect()
  187 | })
  188 | 
  189 | test("a checked site shows one count on /sites and on its board", async ({page}) => {
  190 |   const problems = watch(page)
  191 |   expect((await page.goto("/sites?q=target"))?.status()).toBe(200)
  192 |   await expect(page.locator("tr[id='directory-target.com'] .pb-directory-count")).toHaveText("3")
  193 |   await problems.expect()
  194 | 
  195 |   expect((await page.goto("/target.com"))?.status()).toBe(200)
  196 |   await expect(page.locator("#pb-site-standing .pb-standing-tools")).toHaveText(/^\s*3 tools\s+· checked/)
  197 |   await expect(page.locator("#pb-site-tools .pb-tool-row-name")).toHaveText(["add_to_cart", "find_store", "search_products"])
  198 |   await problems.expect()
  199 | })
  200 | 
  201 | // Where the For agents title, the count, View more and Copy for your agent are,
  202 | // and the word on its way out, if one is. Given a word, it first changes the
  203 | // count's text to it, as a LiveView patch does, and reads once the page has
  204 | // answered that change.
  205 | async function panel(word: string | null) {
  206 |   if (word) {
  207 |     document.querySelector("#pb-site-tool-count > .rg-status-word__word")!.firstChild!.nodeValue = word
  208 |     await new Promise<void>(resolve => queueMicrotask(resolve))
  209 |   }
  210 |   const boxes = ["#pb-site-agents-title", "#pb-site-tool-count", ".pb-site-agent-toggle", "#pb-site-agent-copy"].map(selector => {
  211 |     const r = document.querySelector(selector)!.getBoundingClientRect()
  212 |     return [r.x, r.y, r.width, r.height].map(Math.round)
  213 |   })
  214 |   const leaving = [...document.querySelectorAll("#pb-site-tool-count-gone > *")].map(gone => gone.textContent)
  215 |   return {boxes, leaving}
  216 | }
  217 | 
  218 | test("a board's tool count swaps its word in place, one word at a time, and nothing beside it moves", async ({page}) => {
  219 |   const problems = watch(page)
  220 |   expect((await page.goto("/target.com"))?.status()).toBe(200)
  221 |   await expect(page.locator("[data-phx-session].phx-connected:has(#pb-site-tool-count)")).toBeAttached()
  222 |   const count = page.locator("#pb-site-tool-count")
  223 |   await expect(count).toHaveJSProperty("innerText", "Agents see 3 WebMCP Tools")
  224 |   const before = await page.evaluate(panel, null)
  225 |   expect(before.leaving).toEqual([])
  226 | 
  227 |   const during = await page.evaluate(panel, "Looking for WebMCP tools…")
  228 |   expect(during.leaving, "the old word leaves from its copy").toEqual(["Agents see 3 WebMCP Tools"])
  229 |   expect(during.boxes, "the panel as the word changes").toEqual(before.boxes)
  230 | 
  231 |   await expect(page.locator("#pb-site-tool-count-gone > *")).toHaveCount(0)
  232 |   await expect(count).toHaveJSProperty("innerText", "Looking for WebMCP tools…")
> 233 |   expect((await page.evaluate(panel, null)).boxes, "the panel once the word has changed").toEqual(before.boxes)
      |                                                                                           ^ Error: the panel once the word has changed
  234 |   await problems.expect()
  235 | })
  236 | 
  237 | test("a site not checked yet says Not checked on /sites and on its board", async ({page}) => {
  238 |   const problems = watch(page)
  239 |   expect((await page.goto("/sites?q=keyfleet"))?.status()).toBe(200)
  240 |   await expect(page.locator("tr[id='directory-keyfleet.ai'] .pb-directory-count")).toHaveText("Not checked")
  241 |   await problems.expect()
  242 | 
  243 |   expect((await page.goto("/keyfleet.ai"))?.status()).toBe(200)
  244 |   await expect(page.locator("#pb-site-standing .pb-standing-tools")).toHaveText("Not checked")
  245 |   await problems.expect()
  246 | })
  247 | 
  248 | test("a board's Address filter lists the posts about one address of the site", async ({page}) => {
  249 |   const problems = watch(page)
  250 |   expect((await page.goto("/autocad.com"))?.status()).toBe(200)
  251 |   // The tool is on the page the directory lists at web.autocad.com.
  252 |   await expect(page.locator("#pb-site-standing .pb-standing-tools")).toHaveText(/^\s*1 tool\s+· checked/)
  253 |   const select = page.locator("#pb-address-filter-select")
  254 |   await expect(select.locator("option")).toHaveText(["All", "autocad.com", "web.autocad.com"])
  255 |   await problems.expect()
  256 | 
  257 |   await select.selectOption("web.autocad.com")
  258 |   await Promise.all([
  259 |     page.waitForURL(/\?address=web\.autocad\.com$/),
  260 |     page.locator("#pb-address-filter button").click(),
  261 |   ])
  262 |   await expect(page.locator("#pb-site-posts .pb-row-title")).toHaveText(["Drawings will not open in the web app"])
  263 |   await expect(page.locator("#pb-site-posts .pb-site-chip")).toHaveText(["web.autocad.com"])
  264 |   await expect(select).toHaveValue("web.autocad.com")
  265 |   await problems.expect()
  266 | })
  267 | 
```