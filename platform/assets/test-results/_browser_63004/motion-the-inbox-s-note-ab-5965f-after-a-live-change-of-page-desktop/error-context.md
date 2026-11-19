# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: motion.spec.ts >> the inbox's note about an old page link >> shakes, then rests, after a live change of page
- Location: test/browser/motion.spec.ts:184:3

# Error details

```
Test timeout of 30000ms exceeded.
```

```
Error: locator.waitFor: Test timeout of 30000ms exceeded.
Call log:
  - waiting for locator('[data-phx-main].phx-connected') to be visible
    - waiting for "http://127.0.0.1:63004/account/inbox" navigation to finish...
    - navigated to "http://127.0.0.1:63004/account/inbox"

```

# Test source

```ts
  16  |           faults.push(`outside socket ${socket.url()}`)
  17  |           return socket.close()
  18  |         },
  19  |       )
  20  |       // A page that did not load is the response its check reads; anything
  21  |       // else that fails to load, and anything else logged as an error, is a fault.
  22  |       page.on("console", message => {
  23  |         if (message.type() === "error" && !message.text().startsWith("Failed to load resource"))
  24  |           faults.push(message.text())
  25  |       })
  26  |       page.on("response", response => {
  27  |         if (response.status() >= 400 && response.request().resourceType() !== "document")
  28  |           faults.push(`${response.status()} ${response.url()}`)
  29  |       })
  30  |       await page.addInitScript(recordMoves)
  31  |       await use()
  32  |       expect(faults, "page faults").toEqual([])
  33  |     },
  34  |     {auto: true},
  35  |   ],
  36  | })
  37  | 
  38  | type Recorded = Element & {pbMoves?: string[]; pbInside?: string[]}
  39  | 
  40  | // Installed before any page script runs: each inline transform, translate or
  41  | // opacity written onto an element is kept on the element, in order, and so is each
  42  | // animation or transition the stylesheet starts on it ("animation <name>",
  43  | // "transition <property>").
  44  | function recordMoves() {
  45  |   const note = (el: Node) => {
  46  |     if (!(el instanceof HTMLElement || el instanceof SVGElement)) return
  47  |     const {transform, translate, opacity} = el.style
  48  |     const move = [
  49  |       transform && `transform ${transform}`,
  50  |       translate && translate !== "none" && `translate ${translate}`,
  51  |       opacity && `opacity ${opacity}`,
  52  |     ].filter(Boolean)
  53  |     if (move.length > 0) ((el as Recorded).pbMoves ??= []).push(move.join("; "))
  54  |   }
  55  | 
  56  |   new MutationObserver(changes => {
  57  |     for (const change of changes) {
  58  |       if (change.type === "attributes") note(change.target)
  59  |       change.addedNodes.forEach(note)
  60  |     }
  61  |   }).observe(document, {subtree: true, childList: true, attributes: true, attributeFilter: ["style"]})
  62  | 
  63  |   const started = (move: string) => (event: Event) =>
  64  |     ((event.target as Recorded).pbMoves ??= []).push(`${move} ${(event as AnimationEvent & TransitionEvent)[move === "animation" ? "animationName" : "propertyName"]}`)
  65  |   document.addEventListener("animationstart", started("animation"), true)
  66  |   document.addEventListener("transitionstart", started("transition"), true)
  67  | }
  68  | 
  69  | /**
  70  |  * Starts keeping, on this element, the moves written onto anything inside it,
  71  |  * including pieces that are gone again by the time the check reads them.
  72  |  */
  73  | export const watchInside = (locator: Locator) =>
  74  |   locator.evaluate(root => {
  75  |     const kept: string[] = ((root as Recorded).pbInside = [])
  76  |     new MutationObserver(changes => {
  77  |       for (const change of changes) {
  78  |         const {transform, translate, opacity} = (change.target as HTMLElement).style
  79  |         if (change.target !== root && (transform || (translate && translate !== "none") || opacity))
  80  |           kept.push(`${transform} ${translate} ${opacity}`.trim())
  81  |       }
  82  |     }).observe(root, {subtree: true, attributes: true, attributeFilter: ["style"]})
  83  |   })
  84  | 
  85  | /** The moves written inside this element since `watchInside`. */
  86  | export const movesInside = (locator: Locator) => locator.evaluate(el => (el as Recorded).pbInside ?? [])
  87  | 
  88  | /** The moves written onto this element since the page loaded. */
  89  | export const movesOf = (locator: Locator) => locator.evaluate(el => (el as Recorded).pbMoves ?? [])
  90  | 
  91  | /** The moves recorded on this element and on everything inside it. */
  92  | export const movesWithin = (locator: Locator) =>
  93  |   locator.evaluate(root =>
  94  |     [root, ...root.querySelectorAll("*")].flatMap(el => (el as Recorded).pbMoves ?? []),
  95  |   )
  96  | 
  97  | /** Forgets the moves recorded so far on every element of the page. */
  98  | export const forgetMoves = (page: Page) =>
  99  |   page.evaluate(() => document.querySelectorAll("*").forEach(el => delete (el as Recorded).pbMoves))
  100 | 
  101 | /** The element's inline style, "" when it has none. */
  102 | export const inlineStyle = (locator: Locator) => locator.evaluate(el => (el.getAttribute("style") ?? "").trim())
  103 | 
  104 | /**
  105 |  * Waits until the element has no inline style and nothing animates on it: its
  106 |  * motion has handed it back to the stylesheet, and the stylesheet is still.
  107 |  */
  108 | export const toRest = (locator: Locator) =>
  109 |   expect
  110 |     .poll(async () => [await inlineStyle(locator), await locator.evaluate(el => el.getAnimations().length)], {
  111 |       timeout: 5_000,
  112 |     })
  113 |     .toEqual(["", 0])
  114 | 
  115 | /** Waits for the live page to connect. */
> 116 | export const connected = (page: Page) => page.locator("[data-phx-main].phx-connected").waitFor()
      |                                                                                        ^ Error: locator.waitFor: Test timeout of 30000ms exceeded.
  117 | 
  118 | /** Presses a control the way this project's reader does: a tap on the phone, a click with a mouse. */
  119 | export const press = (locator: Locator, isMobile: boolean) => (isMobile ? locator.tap() : locator.click())
  120 | 
  121 | export {expect}
  122 | 
```