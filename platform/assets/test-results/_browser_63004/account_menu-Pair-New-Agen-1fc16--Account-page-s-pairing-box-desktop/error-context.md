# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: account_menu.spec.ts >> Pair New Agent in the menu lands on the Account page's pairing box
- Location: test/browser/account_menu.spec.ts:148:1

# Error details

```
Error: expect(locator).toBeFocused() failed

Locator:  locator('#account-pairing').getByRole('radio').first()
Expected: focused
Received: inactive
Timeout:  5000ms

Call log:
  - Expect "toBeFocused" locator('#account-pairing').getByRole('radio').first() with timeout 5000ms
  - waiting for locator('#account-pairing').getByRole('radio').first()
    14 × locator resolved to <input type="radio" value="other" name="harness" data-phx-loc="548" class="rg-account__radio"/>
       - unexpected value "inactive"

```

```yaml
- radio "Any agent"
```

# Test source

```ts
  59  |     // Off the list, still inside the menu, so it stays open.
  60  |     await menu(page).locator(".rg-account-menu__name").hover()
  61  |     await expect.poll(opacity).toBe("0")
  62  |     await manage.focus()
  63  |     await expect.poll(opacity).toBe("1")
  64  |   }
  65  |   await manage.click()
  66  |   await expect(page).toHaveURL(/\/account#account-agents$/)
  67  |   await expect(page.locator("#account-agents")).toBeVisible()
  68  |   await expect(menu(page)).toBeHidden()
  69  |   await problems.expect()
  70  | })
  71  | 
  72  | // Found on 21 Oct (Sean), when the account's things were in a panel down the right:
  73  | // it slid in beside the header and cut its bottom line short. The menu hangs under
  74  | // the button instead, and the header and the page keep their whole width.
  75  | test("the account menu hangs under its button, the page keeps its width, and Escape closes it", async ({page, isMobile}) => {
  76  |   const problems = watch(page)
  77  |   for (const width of isMobile ? [390, 320] : [1280, 2000]) {
  78  |     await page.setViewportSize({width, height: 900})
  79  |     await page.goto("/about")
  80  |     await ready(page)
  81  |     const header = page.locator(".pb-frame > :first-child")
  82  |     const content = page.locator("#pb-content")
  83  |     const closed = {header: (await header.boundingBox())!, content: (await content.boundingBox())!}
  84  |     await openMenu(page)
  85  | 
  86  |     const button = (await chip(page).boundingBox())!
  87  |     const box = (await menu(page).boundingBox())!
  88  |     // Below the button, inside the screen, its right edge near the button's.
  89  |     expect(box.y).toBeGreaterThanOrEqual(button.y + button.height)
  90  |     expect(box.x).toBeGreaterThanOrEqual(0)
  91  |     expect(box.x + box.width).toBeLessThanOrEqual(width)
  92  |     if (!isMobile) expect(Math.abs(box.x + box.width - (button.x + button.width))).toBeLessThan(2)
  93  |     expect(await header.boundingBox()).toEqual(closed.header)
  94  |     expect(await content.boundingBox()).toEqual(closed.content)
  95  |     expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
  96  | 
  97  |     await menu(page).getByRole("link", {name: "Manage Account"}).focus()
  98  |     await page.keyboard.press("Escape")
  99  |     await expect(menu(page)).toBeHidden()
  100 |     await expect(chip(page)).toBeFocused()
  101 |   }
  102 |   await problems.expect()
  103 | })
  104 | 
  105 | test("the account menu opens from the keyboard, is named for the person, and a press outside closes it", async ({page}) => {
  106 |   const problems = watch(page)
  107 |   await page.goto("/about")
  108 |   await ready(page)
  109 |   await chip(page).focus()
  110 |   await page.keyboard.press("Enter")
  111 |   await expect(menu(page)).toBeVisible()
  112 |   await expect(menu(page)).toHaveRole("region")
  113 |   await expect(menu(page)).toHaveAccessibleName(await page.locator(".pb-account-name").innerText())
  114 |   // A press beside the menu, or below it where it spans a phone's screen.
  115 |   const box = (await menu(page).boundingBox())!
  116 |   await page.mouse.click(box.x > 40 ? box.x / 2 : box.x + box.width / 2, box.y + box.height + 20)
  117 |   await expect(menu(page)).toBeHidden()
  118 |   await problems.expect()
  119 | })
  120 | 
  121 | test("asked for less motion, the account menu appears at once", async ({page}) => {
  122 |   const problems = watch(page)
  123 |   await page.emulateMedia({reducedMotion: "reduce"})
  124 |   await page.goto("/about")
  125 |   await ready(page)
  126 |   await chip(page).click()
  127 |   await expect(menu(page)).toBeVisible()
  128 |   expect(await menu(page).evaluate(element => element.getAnimations().length)).toBe(0)
  129 |   await problems.expect()
  130 | })
  131 | 
  132 | test("Manage Account opens this site's Account page and the menu closes", async ({page}) => {
  133 |   const problems = watch(page)
  134 |   // From a live page and from a page with no live part of its own.
  135 |   for (const start of ["/offers", "/about"]) {
  136 |     await page.goto(start)
  137 |     await ready(page)
  138 |     await openMenu(page)
  139 |     await expect(menu(page).getByRole("button", {name: "Sign out"})).toBeVisible()
  140 |     await menu(page).getByRole("link", {name: "Manage Account"}).click()
  141 |     await expect(page).toHaveURL(/\/account$/)
  142 |     await expect(page.locator("#account-agents")).toBeVisible()
  143 |     await expect(menu(page)).toBeHidden()
  144 |   }
  145 |   await problems.expect()
  146 | })
  147 | 
  148 | test("Pair New Agent in the menu lands on the Account page's pairing box", async ({page}) => {
  149 |   const problems = watch(page)
  150 |   await page.goto("/about")
  151 |   await ready(page)
  152 |   await openMenu(page)
  153 |   await menu(page).getByRole("link", {name: "Pair New Agent"}).click()
  154 |   await expect(page).toHaveURL(/\/account#account-pairing$/)
  155 |   await expect(menu(page)).toBeHidden()
  156 |   const pairing = page.locator("#account-pairing")
  157 |   await expect(pairing).toBeInViewport()
  158 |   // The keyboard starts on the agent choice.
> 159 |   await expect(pairing.getByRole("radio").first()).toBeFocused()
      |                                                    ^ Error: expect(locator).toBeFocused() failed
  160 | 
  161 |   // Pressed again from the same address after scrolling away, it moves there again.
  162 |   await page.evaluate(() => window.scrollTo({top: 0}))
  163 |   await expect(pairing.getByRole("heading", {name: "Pair New Agent"})).not.toBeInViewport()
  164 |   await ready(page)
  165 |   await openMenu(page)
  166 |   await menu(page).getByRole("link", {name: "Pair New Agent"}).click()
  167 |   await expect(menu(page)).toBeHidden()
  168 |   await expect(pairing).toBeInViewport()
  169 |   await expect(pairing.getByRole("radio").first()).toBeFocused()
  170 | 
  171 |   // The Account page's own Pair New Agent, under the agents, goes to the same box.
  172 |   await page.evaluate(() => window.scrollTo({top: 0}))
  173 |   await page.locator("#account-agents").getByRole("link", {name: "Pair New Agent"}).click()
  174 |   await expect(pairing).toBeInViewport()
  175 |   await expect(pairing.getByRole("radio").first()).toBeFocused()
  176 |   await problems.expect()
  177 | })
  178 | 
  179 | // Narrower than 22.5rem the header has no room for the balance, so the account menu
  180 | // shows it, in the header's words, and the row opens the same Buy Credits dialog.
  181 | test("on the narrowest phones the balance is in the account menu and opens Buy Credits", async ({page, isMobile}) => {
  182 |   test.skip(!isMobile, "only the narrowest phones move the balance")
  183 |   const problems = watch(page)
  184 |   await page.setViewportSize({width: 320, height: 900})
  185 |   await page.goto("/about")
  186 |   await ready(page)
  187 |   await expect(page.locator("#pb-credits-balance")).toBeHidden()
  188 |   await openMenu(page)
  189 | 
  190 |   const row = page.locator("#account-menu-credits")
  191 |   await expect(row).toBeVisible()
  192 |   // The header's words: its balance's name once read, as "0 Credits".
  193 |   await expect(page.locator("#pb-credits-balance")).toHaveAttribute("aria-label", /^\S+ Credits$/)
  194 |   const words = (await page.locator("#pb-credits-balance").getAttribute("aria-label"))!
  195 |   expect(words).toMatch(/^\S+ Credits$/)
  196 |   await expect(row).toHaveText(words)
  197 |   await expect(row).toHaveAccessibleName(words)
  198 |   expect((await row.boundingBox())!.height).toBeGreaterThanOrEqual(44)
  199 |   expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(320)
  200 | 
  201 |   await row.click()
  202 |   await expect(menu(page)).toBeHidden()
  203 |   await expect(page.getByRole("dialog", {name: "Buy Credits"})).toBeVisible()
  204 |   await page.keyboard.press("Escape")
  205 |   await expect(page.getByRole("dialog", {name: "Buy Credits"})).toBeHidden()
  206 |   await expect(chip(page)).toBeFocused()
  207 |   await problems.expect()
  208 | })
  209 | 
  210 | test("wider than the narrowest phones the balance stays in the header, not the menu", async ({page, isMobile}) => {
  211 |   const problems = watch(page)
  212 |   const width = isMobile ? 390 : 1280
  213 |   await page.setViewportSize({width, height: 900})
  214 |   await page.goto("/about")
  215 |   await ready(page)
  216 |   const balance = page.locator("#pb-credits-balance")
  217 |   await expect(balance).toBeVisible()
  218 |   // A phone's header keeps the figure and leaves the word out.
  219 |   await expect(balance.locator(".pb-credits-unit")).toBeVisible({visible: !isMobile})
  220 |   await openMenu(page)
  221 |   await expect(page.locator("#account-menu-credits")).toBeHidden()
  222 |   await page.keyboard.press("Escape")
  223 |   await balance.click()
  224 |   await expect(page.getByRole("dialog", {name: "Buy Credits"})).toBeVisible()
  225 |   await problems.expect()
  226 | })
  227 | 
  228 | // Found in review on 29 Oct: the header left the word "Credits" out below 900px,
  229 | // where the Regent template leaves it out only below 768px. From 768px the balance
  230 | // keeps its word, and the header still fits on one line.
  231 | test("from 768px the header's balance keeps the word Credits, and the header fits", async ({page, isMobile}) => {
  232 |   test.skip(isMobile, "widths a desktop reaches")
  233 |   const problems = watch(page)
  234 |   for (const [width, word] of [[767, false], [768, true], [899, true], [1099, true]] as const) {
  235 |     await page.setViewportSize({width, height: 900})
  236 |     await page.goto("/about")
  237 |     await ready(page)
  238 |     const balance = page.locator("#pb-credits-balance")
  239 |     await expect(balance.locator(".pb-credits-unit")).toBeVisible({visible: word})
  240 |     const header = (await page.locator("header.pb-masthead").boundingBox())!
  241 |     for (const control of await page.locator("header.pb-masthead").locator("a:visible, button:visible").all()) {
  242 |       const box = (await control.boundingBox())!
  243 |       expect(box.x + box.width, `${width}px`).toBeLessThanOrEqual(header.x + header.width)
  244 |       expect(box.y + box.height, `${width}px, one line`).toBeLessThanOrEqual(header.y + header.height)
  245 |     }
  246 |     expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width)
  247 |   }
  248 |   await problems.expect()
  249 | })
  250 | 
```