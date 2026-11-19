# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: people_admin.spec.ts >> a moderator finds a person in the list and opens their page
- Location: test/browser/people_admin.spec.ts:10:1

# Error details

```
Error: expect(received).toEqual(expected) // deep equality

- Expected  - 1
+ Received  + 3

- Array []
+ Array [
+   "content is 704px wider than the screen",
+ ]
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
      - button "0x9999..9999" [ref=e32] [cursor=pointer]
    - main [ref=e42]:
      - generic [ref=e44]:
        - generic [ref=e63]:
          - paragraph [ref=e64]:
            - navigation "Admin" [ref=e65]:
              - generic [ref=e66]: People
              - link "Messages" [ref=e67] [cursor=pointer]:
                - /url: /admin/messages
          - heading "People" [level=1] [ref=e68]
        - generic [ref=e69]: Private
      - generic [ref=e71]:
        - generic [ref=e72]:
          - generic [ref=e73]: Find
          - searchbox "Find" [ref=e75]
        - generic [ref=e77]:
          - checkbox "Suspended" [ref=e78]
          - text: Suspended
      - list [ref=e79]:
        - listitem [ref=e80]:
          - generic [ref=e81]:
            - strong [ref=e82]:
              - link "0x7777..7777" [ref=e83] [cursor=pointer]:
                - /url: /admin/people/agt_419b87145d2449dc9c70165bdcaf92cd
            - generic [ref=e85]: Active
            - generic [ref=e86]:
              - text: Joined
              - time [ref=e87]: 14 Nov 2026, 08:39 UTC
        - listitem [ref=e88]:
          - generic [ref=e89]:
            - strong [ref=e90]:
              - link "0x7777..7777" [ref=e91] [cursor=pointer]:
                - /url: /admin/people/agt_ab1e2e8263c04ca58dc485f72a3c0892
            - generic [ref=e93]: Active
            - generic [ref=e94]:
              - text: Joined
              - time [ref=e95]: 14 Nov 2026, 08:39 UTC
        - listitem [ref=e96]:
          - generic [ref=e97]:
            - strong [ref=e98]:
              - link "0x7777..7777" [ref=e99] [cursor=pointer]:
                - /url: /admin/people/agt_d25e21b9a1644c24850aeac264470509
            - generic [ref=e101]: Active
            - generic [ref=e102]:
              - text: Joined
              - time [ref=e103]: 14 Nov 2026, 08:39 UTC
        - listitem [ref=e104]:
          - generic [ref=e105]:
            - strong [ref=e106]:
              - link "0x7777..7777" [ref=e107] [cursor=pointer]:
                - /url: /admin/people/agt_6f14ff3d968b4ce4bd2382514f9c252c
            - generic [ref=e109]: Active
            - generic [ref=e110]:
              - text: Joined
              - time [ref=e111]: 14 Nov 2026, 08:39 UTC
        - listitem [ref=e112]:
          - generic [ref=e113]:
            - strong [ref=e114]:
              - link "0x7777..7777" [ref=e115] [cursor=pointer]:
                - /url: /admin/people/agt_2eb8860dbbc341ca9a1f36321f6f91a3
            - generic [ref=e117]: Active
            - generic [ref=e118]:
              - text: Joined
              - time [ref=e119]: 14 Nov 2026, 08:39 UTC
        - listitem [ref=e120]:
          - generic [ref=e121]:
            - strong [ref=e122]:
              - link "0x7777..7777" [ref=e123] [cursor=pointer]:
                - /url: /admin/people/agt_5d0fa0f561be4adfb4c760b1915f19ec
            - generic [ref=e125]: Active
            - generic [ref=e126]:
              - text: Joined
              - time [ref=e127]: 14 Nov 2026, 08:39 UTC
        - listitem [ref=e128]:
          - generic [ref=e129]:
            - strong [ref=e130]:
              - link "0x7777..7777" [ref=e131] [cursor=pointer]:
                - /url: /admin/people/agt_403b950ffecb478ba4fa33f31060d7db
            - generic [ref=e133]: Active
            - generic [ref=e134]:
              - text: Joined
              - time [ref=e135]: 14 Nov 2026, 08:39 UTC
        - listitem [ref=e136]:
          - generic [ref=e137]:
            - strong [ref=e138]:
              - link "0x7777..7777" [ref=e139] [cursor=pointer]:
                - /url: /admin/people/agt_d83e7163f3d2452fa73dd6709482976d
            - generic [ref=e141]: Active
            - generic [ref=e142]:
              - text: Joined
              - time [ref=e143]: 14 Nov 2026, 08:38 UTC
        - listitem [ref=e144]:
          - generic [ref=e145]:
            - strong [ref=e146]:
              - link "0x7777..7777" [ref=e147] [cursor=pointer]:
                - /url: /admin/people/agt_90080e2e5d3b412291f37a0511bc80b7
            - generic [ref=e149]: Active
            - generic [ref=e150]:
              - text: Joined
              - time [ref=e151]: 14 Nov 2026, 08:38 UTC
        - listitem [ref=e152]:
          - generic [ref=e153]:
            - strong [ref=e154]:
              - link "0x7777..7777" [ref=e155] [cursor=pointer]:
                - /url: /admin/people/agt_3a72d5132b244770a7e062785124b421
            - generic [ref=e157]: Active
            - generic [ref=e158]:
              - text: Joined
              - time [ref=e159]: 14 Nov 2026, 08:38 UTC
        - listitem [ref=e160]:
          - generic [ref=e161]:
            - strong [ref=e162]:
              - link "0x7777..7777" [ref=e163] [cursor=pointer]:
                - /url: /admin/people/agt_070082c6521544f18417bf28f93186eb
            - generic [ref=e165]: Active
            - generic [ref=e166]:
              - text: Joined
              - time [ref=e167]: 14 Nov 2026, 08:38 UTC
        - listitem [ref=e168]:
          - generic [ref=e169]:
            - strong [ref=e170]:
              - link "0x7777..7777" [ref=e171] [cursor=pointer]:
                - /url: /admin/people/agt_b8c0224af025449a898819b1e74184fe
            - generic [ref=e173]: Active
            - generic [ref=e174]:
              - text: Joined
              - time [ref=e175]: 14 Nov 2026, 08:38 UTC
        - listitem [ref=e176]:
          - generic [ref=e177]:
            - strong [ref=e178]:
              - link "0x7777..7777" [ref=e179] [cursor=pointer]:
                - /url: /admin/people/agt_2d25ac7beadb4d508041ff48ae09cae1
            - generic [ref=e181]: Active
            - generic [ref=e182]:
              - text: Joined
              - time [ref=e183]: 14 Nov 2026, 08:38 UTC
        - listitem [ref=e184]:
          - generic [ref=e185]:
            - strong [ref=e186]:
              - link "0x7777..7777" [ref=e187] [cursor=pointer]:
                - /url: /admin/people/agt_5601901b97fa4113b28cfd393055c7ea
            - generic [ref=e189]: Active
            - generic [ref=e190]:
              - text: Joined
              - time [ref=e191]: 14 Nov 2026, 08:38 UTC
        - listitem [ref=e192]:
          - generic [ref=e193]:
            - strong [ref=e194]:
              - link "0x7777..7777" [ref=e195] [cursor=pointer]:
                - /url: /admin/people/agt_a4d8c60378c94e32887116d340132097
            - generic [ref=e197]: Active
            - generic [ref=e198]:
              - text: Joined
              - time [ref=e199]: 14 Nov 2026, 08:38 UTC
        - listitem [ref=e200]:
          - generic [ref=e201]:
            - strong [ref=e202]:
              - link "0x7777..7777" [ref=e203] [cursor=pointer]:
                - /url: /admin/people/agt_4f2de1bcc8bb456cbc499c68d14e757c
            - generic [ref=e205]: Active
            - generic [ref=e206]:
              - text: Joined
              - time [ref=e207]: 14 Nov 2026, 08:38 UTC
        - listitem [ref=e208]:
          - generic [ref=e209]:
            - strong [ref=e210]:
              - link "0xaaaa..aaaa" [ref=e211] [cursor=pointer]:
                - /url: /admin/people/agt_8aae98a986dc4b21bc996e1c7a91a2a4
            - generic [ref=e213]: Active
            - generic [ref=e214]:
              - text: Joined
              - time [ref=e215]: 14 Nov 2026, 08:37 UTC
        - listitem [ref=e216]:
          - generic [ref=e217]:
            - strong [ref=e218]:
              - link "0xc947..dbcc" [ref=e219] [cursor=pointer]:
                - /url: /admin/people/agt_afeaf4ace6484229949c4a820d171999
            - generic [ref=e221]: Active
            - generic [ref=e222]:
              - text: Joined
              - time [ref=e223]: 14 Nov 2026, 08:37 UTC
        - listitem [ref=e224]:
          - generic [ref=e225]:
            - strong [ref=e226]:
              - link "0x3e52..d5cf" [ref=e227] [cursor=pointer]:
                - /url: /admin/people/agt_7024cadf216b4c998dde1868d573fde4
            - generic [ref=e229]: Active
            - generic [ref=e230]:
              - text: Joined
              - time [ref=e231]: 14 Nov 2026, 08:37 UTC
        - listitem [ref=e232]:
          - generic [ref=e233]:
            - strong [ref=e234]:
              - link "0x4467..4d5b" [ref=e235] [cursor=pointer]:
                - /url: /admin/people/agt_239d18bdbbdb48be8348e272d6e086c5
            - generic [ref=e237]: Active
            - generic [ref=e238]:
              - text: Joined
              - time [ref=e239]: 14 Nov 2026, 08:37 UTC
        - listitem [ref=e240]:
          - generic [ref=e241]:
            - strong [ref=e242]:
              - link "0x9999..9999" [ref=e243] [cursor=pointer]:
                - /url: /admin/people/agt_4daabdf0430646ea9151144a26b9822c
            - generic [ref=e245]: Active
            - generic [ref=e246]:
              - text: Joined
              - time [ref=e247]: 14 Nov 2026, 08:37 UTC
        - listitem [ref=e248]:
          - generic [ref=e249]:
            - strong [ref=e250]:
              - link "Walk desktopWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW" [ref=e251] [cursor=pointer]:
                - /url: /admin/people/agt_05ea3cf1664f4d6e8e341dc7c31661dc
            - generic [ref=e253]: Active
            - generic [ref=e254]:
              - text: Joined
              - time [ref=e255]: 14 Nov 2026, 08:37 UTC
        - listitem [ref=e256]:
          - generic [ref=e257]:
            - strong [ref=e258]:
              - link "0xcccc..cccc" [ref=e259] [cursor=pointer]:
                - /url: /admin/people/agt_f57c47a4e6684ba598159c81a13a6e35
            - generic [ref=e261]: Active
            - generic [ref=e262]:
              - text: Joined
              - time [ref=e263]: 14 Nov 2026, 08:37 UTC
        - listitem [ref=e264]:
          - generic [ref=e265]:
            - strong [ref=e266]:
              - link "0xbbbb..bbbb" [ref=e267] [cursor=pointer]:
                - /url: /admin/people/agt_44307c58b88845e8af4ad96fb0cdfdda
            - generic [ref=e269]: Active
            - generic [ref=e270]:
              - text: Joined
              - time [ref=e271]: 14 Nov 2026, 08:37 UTC
    - contentinfo [ref=e274]:
      - generic [ref=e275]:
        - link "Patchbay on X" [ref=e276] [cursor=pointer]:
          - /url: https://x.com/regents_sh
        - link "Patchbay on GitHub" [ref=e279] [cursor=pointer]:
          - /url: https://github.com/regents-ai
      - navigation "About Patchbay" [ref=e282]:
        - link "Buy $REGENT" [ref=e283] [cursor=pointer]:
          - /url: https://app.uniswap.org/explore/tokens/base/0x6f89bcA4eA5931EdFCB09786267b251DeE752b07
        - link "About" [ref=e284] [cursor=pointer]:
          - /url: /about
        - link "Developer docs" [ref=e285] [cursor=pointer]:
          - /url: /docs
        - button "Agent guide" [ref=e286] [cursor=pointer]
        - generic [ref=e287]:
          - link "Privacy policy" [ref=e288] [cursor=pointer]:
            - /url: /privacy
          - link "Terms of use" [ref=e289] [cursor=pointer]:
            - /url: /terms
      - paragraph [ref=e290]: © 2026 Regents Labs
```

# Test source

```ts
  1  | import {test as base, expect, type BrowserContext, type Page} from "@playwright/test"
  2  | 
  3  | // The walk never leaves this machine. The page's sign-in bridge, the only part
  4  | // that talks to Privy, is answered by a stand-in that holds no Privy sign-in;
  5  | // any other outside address is refused and fails the check that reached for it.
  6  | const bridge = /^\/assets\/js\/privy_bridge(-[0-9a-f]+)?\.js$/
  7  | // The same exports as assets/js/privy_bridge.tsx, each answering as a browser with
  8  | // no Privy sign-in does.
  9  | const signedOut = {ok: false, reason: "signed_out"}
  10 | const standIn = `
  11 | export async function signIn() { return ${JSON.stringify(signedOut)} }
  12 | export async function finishRedirectSignIn() { return ${JSON.stringify(signedOut)} }
  13 | export async function signOut() {}
  14 | export async function activeWallet() { return ${JSON.stringify(signedOut)} }
  15 | export async function activeAddress() { return null }
  16 | export async function addFundsByCard() { return ${JSON.stringify(signedOut)} }
  17 | `
  18 | 
  19 | // Keeps a browser's pages on this machine, and lists what they reached for
  20 | // outside it. Every check's own browser has it; a check that opens a second
  21 | // one gives it the same.
  22 | export async function keepOnThisMachine(context: BrowserContext, baseURL: string) {
  23 |   const site = new URL(baseURL).host
  24 |   const outside: string[] = []
  25 |   await context.route(() => true, route => {
  26 |     const url = new URL(route.request().url())
  27 |     if (url.host !== site) {
  28 |       outside.push(`${route.request().method()} ${url.origin}${url.pathname}`)
  29 |       return route.abort("blockedbyclient")
  30 |     }
  31 |     if (bridge.test(url.pathname))
  32 |       return route.fulfill({contentType: "text/javascript", body: standIn})
  33 |     return route.continue()
  34 |   })
  35 |   return outside
  36 | }
  37 | 
  38 | export const test = base.extend<{onThisMachine: void}>({
  39 |   onThisMachine: [async ({context, baseURL}, use) => {
  40 |     const outside = await keepOnThisMachine(context, baseURL!)
  41 |     await use()
  42 |     expect(outside, "requests that left the machine").toEqual([])
  43 |   }, {auto: true}],
  44 | })
  45 | 
  46 | // A person's saved sign-in, written by sign_in.exs into this run's own folder
  47 | // before the server starts.
  48 | export const signInFile = (person: string) => `test/browser/.auth/${process.env.PATCHBAY_DEV_PARTITION}/${person}.json`
  49 | 
  50 | // The walk's person.
  51 | export const signedIn = {storageState: signInFile("person")}
  52 | 
  53 | // The person who saves their public name (public_name.spec.ts).
  54 | export const namer = {storageState: signInFile("namer")}
  55 | 
  56 | // The post form's live part has joined (PatchbayWeb.PostFormLive): what is typed
  57 | // and pressed from now on reaches it.
  58 | export const formJoined = (page: Page) =>
  59 |   page.locator("[data-phx-session].phx-connected:has(#pb-hero-form)").waitFor({state: "attached"})
  60 | 
  61 | // What a broken page shows: an uncaught error, or content wider than the screen.
  62 | // The width is read once the page has loaded: a page a link has only just opened
  63 | // may not have its styles yet, and is laid out as plain HTML that no visitor sees.
  64 | export function watch(page: Page) {
  65 |   const problems: string[] = []
  66 |   page.on("pageerror", error => problems.push(`page error: ${error.message}`))
  67 |   return {
  68 |     expect: async () => {
  69 |       await page.waitForLoadState()
  70 |       const overflow = await page.evaluate(
  71 |         () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
  72 |       )
  73 |       if (overflow > 0) problems.push(`content is ${overflow}px wider than the screen`)
> 74 |       expect(problems).toEqual([])
     |                        ^ Error: expect(received).toEqual(expected) // deep equality
  75 |     },
  76 |   }
  77 | }
  78 | 
  79 | export {expect}
  80 | 
```