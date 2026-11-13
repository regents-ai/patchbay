import {type Locator, type Page} from "@playwright/test"
import {expect, test} from "./support/motion"
import {watch} from "./support/test"

// View Forum sits right after a row's address on /sites. With a mouse it shows
// while the pointer is on the row or a control in the row has keyboard focus,
// and the row never moves when it does; on a touch screen it always shows, a
// finger tall. Pressing it opens the site's forum and never opens the row.
// An opened row holds the site's home page picture and its tools' names: side
// by side on a wide screen, the picture first on a phone. A long list scrolls
// inside its own box, never sideways.

const opacity = (forum: Locator) => forum.evaluate(el => getComputedStyle(el).opacity)

// Where everything in a row is laid out, transforms aside: the row, the
// name, the address and View Forum's own place.
const layout = (row: Locator) =>
  row.evaluate(tr => {
    const box = (el: Element | null) => {
      const r = el!.getBoundingClientRect()
      return [r.x, r.y, r.width, r.height].map(Math.round)
    }
    const forum = tr.querySelector<HTMLElement>(".pb-directory-forum")!
    return {
      row: box(tr),
      name: box(tr.querySelector(".pb-directory-expand")),
      address: box(tr.querySelector(".pb-directory-url")),
      forum: [forum.offsetLeft, forum.offsetTop, forum.offsetWidth, forum.offsetHeight],
    }
  })

// Opens the row for `host` once the page's live part is joined, and gives back
// what the row opened.
async function open(page: Page, host: string) {
  await expect(page.locator("[data-phx-session].phx-connected:has(#directory-rows)")).toBeAttached()
  await page.locator(`tr[id='directory-${host}'] .pb-directory-expand`).click()
  const detail = page.locator(`[id='tools-${host}']`)
  await expect(detail).toBeVisible()
  return detail
}

// Each "toggle" the page sends its server: a press that opens or closes a row.
function toggles(page: Page) {
  const sent: string[] = []
  page.on("websocket", socket =>
    socket.on("framesent", frame => {
      if (String(frame.payload).includes('"toggle"')) sent.push(String(frame.payload))
    }))
  return sent
}

test("with a mouse, View Forum shows on the row under the pointer and nothing moves", async ({page}, info) => {
  test.skip(info.project.name !== "desktop", "a touch screen always shows it")
  const problems = watch(page)
  expect((await page.goto("/sites"))?.status()).toBe(200)
  const [first, second] = [page.locator(".pb-directory-row").nth(0), page.locator(".pb-directory-row").nth(1)]
  const forum = first.locator("a.pb-directory-forum")

  await page.mouse.move(0, 0)
  expect(await opacity(forum)).toBe("0")
  const before = await layout(first)

  await first.locator(".pb-directory-url").hover()
  await expect.poll(() => opacity(forum)).toBe("1")
  expect(await layout(first), "the row as laid out before and after the pointer arrived").toEqual(before)
  expect(await opacity(second.locator("a.pb-directory-forum")), "another row's View Forum").toBe("0")

  // It comes right after the address.
  const address = await first.locator(".pb-directory-url").boundingBox()
  const button = await forum.boundingBox()
  expect(button!.x).toBeGreaterThanOrEqual(address!.x + address!.width)
  expect(button!.x - (address!.x + address!.width)).toBeLessThan(24)
  await problems.expect()
})

test("with a mouse, keyboard focus in a row shows its View Forum at once", async ({page}, info) => {
  test.skip(info.project.name !== "desktop", "a touch screen always shows it")
  expect((await page.goto("/sites"))?.status()).toBe(200)
  await expect(page.locator("[data-phx-session].phx-connected:has(#directory-rows)")).toBeAttached()
  await page.mouse.move(0, 0)
  const row = page.locator(".pb-directory-row").nth(2)
  const forum = row.locator("a.pb-directory-forum")

  await row.locator(".pb-directory-expand").focus()
  await page.keyboard.press("Tab")
  await expect(row.locator(".pb-directory-url a")).toBeFocused()
  expect(await opacity(forum)).toBe("1")

  await page.keyboard.press("Tab")
  await expect(forum).toBeFocused()
  expect(await opacity(forum)).toBe("1")
  expect(await opacity(page.locator(".pb-directory-row").nth(1).locator("a.pb-directory-forum"))).toBe("0")
})

test("on a touch screen View Forum always shows, a finger tall, beside every row", async ({page}, info) => {
  test.skip(info.project.name === "desktop", "a mouse shows it on the row it is over")
  const problems = watch(page)
  expect((await page.goto("/sites"))?.status()).toBe(200)
  const rows = page.locator(".pb-directory-row")
  for (const n of [0, 1, 2]) {
    const forum = rows.nth(n).locator("a.pb-directory-forum")
    await expect(forum).toBeVisible()
    expect(await opacity(forum)).toBe("1")
    expect((await forum.boundingBox())!.height).toBeGreaterThanOrEqual(44)
    // The name keeps its whole width: it is never cut short.
    const name = rows.nth(n).locator(".pb-directory-name")
    expect(await name.evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true)
  }
  await problems.expect()
})

test("pressing View Forum opens the site's forum and never the row", async ({page}) => {
  const sent = toggles(page)
  expect((await page.goto("/sites"))?.status()).toBe(200)
  // The page's live part is joined, so a press on the row would reach the server.
  await expect(page.locator("[data-phx-session].phx-connected:has(#directory-rows)")).toBeAttached()
  const row = page.locator(".pb-directory-row").first()
  const forum = row.locator("a.pb-directory-forum")
  const href = (await forum.getAttribute("href"))!
  expect(href).toBe(await row.locator("a.pb-directory-posts").getAttribute("href"))

  await row.hover()
  const problems = watch(page)
  const [response] = await Promise.all([page.waitForResponse(r => new URL(r.url()).pathname === href), forum.click()])
  expect(response.status()).toBe(200)
  await expect(page).toHaveURL(new RegExp(`${href.replace(/\./g, "\\.")}$`))
  expect(sent, "row presses sent to the server").toEqual([])
  await problems.expect()
})

test("an opened row holds the home page picture and the tools, side by side on a wide screen", async ({page}, info) => {
  const problems = watch(page)
  expect((await page.goto("/sites"))?.status()).toBe(200)
  const detail = await open(page, "target.com")

  expect(await detail.evaluate(el => [...el.children].map(child => child.tagName))).toEqual(["IMG", "UL"])
  const picture = detail.locator("img.pb-directory-picture")
  await expect.poll(() => picture.evaluate((img: HTMLImageElement) => img.complete && img.naturalWidth > 0)).toBe(true)
  const shot = (await picture.boundingBox())!
  const tools = (await detail.locator(".pb-directory-tool-list").boundingBox())!
  expect(shot.width / shot.height).toBeCloseTo(1.6, 1)

  if (info.project.name === "desktop") {
    expect(tools.x, "the tools start right of the picture").toBeGreaterThanOrEqual(shot.x + shot.width)
    expect(Math.abs(tools.y - shot.y), "the tools and the picture share a top").toBeLessThan(2)
  } else {
    expect(tools.y, "the tools start under the picture").toBeGreaterThanOrEqual(shot.y + shot.height)
    const panel = (await detail.boundingBox())!
    expect(shot.width, "the picture takes the panel's width").toBeGreaterThan(panel.width - 32)
  }
  await problems.expect()
})

test("a long tool list scrolls inside its own box, never sideways", async ({page}) => {
  const problems = watch(page)
  expect((await page.goto("/sites?q=econsor"))?.status()).toBe(200)
  const list = (await open(page, "econsor.de")).locator(".pb-directory-tool-list")

  const fit = () =>
    list.evaluate(el => ({
      height: el.clientHeight,
      scrolls: el.scrollHeight > el.clientHeight,
      sideways: el.scrollWidth > el.clientWidth,
      top: el.scrollTop,
    }))

  const before = await fit()
  expect(before.height).toBeLessThanOrEqual(180)
  expect(before.scrolls).toBe(true)
  expect(before.sideways).toBe(false)
  // Its box takes keyboard focus, so it scrolls without a pointer.
  await list.focus()
  await page.keyboard.press("PageDown")
  await expect.poll(async () => (await fit()).top).toBeGreaterThan(0)
  await problems.expect()
})
