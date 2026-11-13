import {readFileSync, writeFileSync} from "node:fs"
import {basename} from "node:path"
import {crc32, deflateSync} from "node:zlib"
import type {Locator, Page} from "@playwright/test"
import {expect, signInFile, test, watch} from "./support/test"

// Pictures on the post form: added with Add pictures, shown small and named by
// their files, each taken away with its own Remove, four at most, kept through
// a press that is turned down, and posted with the post as shown. The second
// person posts, on an hourly share of their own (support/sign_in.exs). At 1280
// and 390; the 320 phone draws the same form.

test.use({storageState: signInFile("other")})

test.beforeEach(async ({page}, info) => {
  test.skip(info.project.name === "small phone", "checked at 1280 and 390")
  // The site's tool check is answered here, as in post_form.spec.ts: it is not
  // what this walk is about.
  await page.route(/\/fix-check\?/, route =>
    route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({status: "none", said: "", tools: [], directory: false}),
    }))
})

// A small picture of one colour, a real PNG, written to the test's own folder.
function png(name: string, colour: [number, number, number]) {
  const chunk = (type: string, data: Buffer) => {
    const named = Buffer.concat([Buffer.from(type, "latin1"), data])
    const length = Buffer.alloc(4)
    length.writeUInt32BE(data.length)
    const sum = Buffer.alloc(4)
    sum.writeUInt32BE(crc32(named))
    return Buffer.concat([length, named, sum])
  }
  const [width, height] = [64, 48]
  const header = Buffer.alloc(13)
  header.writeUInt32BE(width, 0)
  header.writeUInt32BE(height, 4)
  header.set([8, 2], 8) // 8 bits a channel, red, green and blue
  const row = Buffer.from([0, ...Array.from({length: width}, () => colour).flat()])
  const path = test.info().outputPath(name)
  writeFileSync(path, Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(Buffer.concat(Array.from({length: height}, () => row)))),
    chunk("IEND", Buffer.alloc(0)),
  ]))
  return path
}

// Add pictures opens the device's chooser, which is given these files.
async function choose(add: Locator, paths: string[]) {
  const [chooser] = await Promise.all([add.page().waitForEvent("filechooser"), add.click()])
  await chooser.setFiles(paths)
}

// Dropped on the box around Add pictures, as a file dragged from the desktop is.
async function drop(zone: Locator, path: string) {
  const transfer = await zone.page().evaluateHandle(([bytes, name]) => {
    const transfer = new DataTransfer()
    transfer.items.add(new File([Uint8Array.from(atob(bytes), character => character.charCodeAt(0))], name, {type: "image/png"}))
    return transfer
  }, [readFileSync(path).toString("base64"), basename(path)])
  await zone.dispatchEvent("dragover", {dataTransfer: transfer})
  await expect(zone).toHaveAttribute("data-pb-dragging", "")
  await zone.dispatchEvent("drop", {dataTransfer: transfer})
  await expect(zone).not.toHaveAttribute("data-pb-dragging")
}

// The names of the files the form will send with the post.
const sending = (page: Page) =>
  page.locator("#pb-hero-pictures").evaluate(field => Array.from((field as HTMLInputElement).files!, file => file.name))

// Each picture shown is drawn from its file, not a broken image.
const drawn = (pictures: Locator) =>
  pictures.evaluateAll(images => images.every(image => (image as HTMLImageElement).naturalWidth === 64))

test("pictures are added, shown, taken away and posted with the post, four at most", async ({page}) => {
  const problems = watch(page)
  const [red, green, blue, gold, plum, teal] = (
    [["red", [200, 40, 40]], ["green", [40, 160, 80]], ["blue", [40, 80, 200]],
      ["gold", [220, 170, 30]], ["plum", [120, 40, 120]], ["teal", [30, 140, 150]]] as const
  ).map(([name, colour]) => png(`${name}.png`, [...colour]))
  const notes = test.info().outputPath("notes.txt")
  writeFileSync(notes, "not a picture")
  const large = test.info().outputPath("large.png")
  writeFileSync(large, Buffer.alloc(3 * 1024 * 1024 + 1))

  await page.goto("/hermes")
  await page.locator("#pb-hero-details > summary").click()
  const box = page.locator("#pb-hero-pictures-box")
  const add = box.getByRole("button", {name: "Add pictures"})
  const shown = box.locator(".pb-picture img")
  const count = box.locator("[data-pb-pictures-count]")
  const said = page.locator("#pb-hero-pictures-errors > p")
  const removeOf = (name: string) => box.locator(".pb-picture", {has: page.locator(`img[alt="${name}"]`)}).getByRole("button", {name: "Remove"})
  await expect(count).toHaveText("0/4")
  await expect(shown).toHaveCount(0)

  // Two, shown small, each named by its file.
  await choose(add, [red, green])
  await expect(shown).toHaveCount(2)
  await expect(shown.nth(0)).toHaveAccessibleName("red.png")
  await expect(shown.nth(1)).toHaveAccessibleName("green.png")
  await expect.poll(() => drawn(shown)).toBe(true)
  expect(await sending(page)).toEqual(["red.png", "green.png"])
  await expect(count).toHaveText("2/4")
  await expect(said).toHaveCount(0)

  // Its Remove is a finger's 44 px, named Remove and described by its picture,
  // and takes it away; the focus goes to the Remove left.
  const remove = removeOf("red.png")
  await expect(remove).toHaveAccessibleDescription("red.png")
  // Read once the picture has settled in from its slight growth.
  await expect.poll(async () => {
    const target = (await remove.boundingBox())!
    return Math.min(target.width, target.height)
  }).toBeGreaterThanOrEqual(44)
  await remove.click()
  await expect(shown).toHaveCount(1)
  expect(await sending(page)).toEqual(["green.png"])
  await expect(count).toHaveText("1/4")
  await expect(removeOf("green.png")).toBeFocused()

  // Another kind of file, or one too large, is not added, and that is said.
  await choose(add, [notes, large])
  await expect(shown).toHaveCount(1)
  await expect(said).toHaveCount(1)
  await expect(said).toBeInViewport()

  // Four chosen with one in: the first three join it, the rest are said, and
  // the button shows the form is full.
  await choose(add, [blue, gold, plum, teal])
  await expect(shown).toHaveCount(4)
  expect(await sending(page)).toEqual(["green.png", "blue.png", "gold.png", "plum.png"])
  await expect(count).toHaveText("4/4")
  await expect(said).toHaveCount(1)
  await expect(add).toHaveAttribute("aria-disabled", "true")

  // A fifth: the full button opens no chooser, and says why. It still takes a
  // press, which Playwright's click would wait to be allowed.
  let opened = false
  page.on("filechooser", () => (opened = true))
  const before = (await said.textContent())!
  await add.click({force: true})
  await expect(said).not.toHaveText(before)
  expect(opened).toBe(false)
  expect(await sending(page)).toHaveLength(4)

  // Taken away from the keyboard, a picture frees its place for another,
  // dropped this time.
  await removeOf("gold.png").focus()
  await page.keyboard.press("Enter")
  await expect(shown).toHaveCount(3)
  await expect(add).toHaveAttribute("aria-disabled", "false")
  await drop(box.locator("[data-pb-pictures-drop]"), teal)
  expect(await sending(page)).toEqual(["green.png", "blue.png", "plum.png", "teal.png"])

  // A press turned down, here over an empty title, keeps the pictures.
  await page.locator("[data-pb-preview]").click()
  await expect(page.locator("#pb-fix-goal-errors > p")).toHaveCount(1)
  await expect(shown).toHaveCount(4)
  expect(await sending(page)).toHaveLength(4)

  // Posted, the four go with the post.
  await page.locator("#pb-fix-goal").fill(`Booking tool shows the wrong dates ${Math.random().toString(36).slice(2, 8)}`)
  await page.locator("#pb-fix-site").fill("example.com")
  await page.locator("#pb-hero-body").fill("Tried it twice in a fresh session, and once more after signing in again.")
  await page.locator("[data-pb-preview]").click()
  await expect(page.locator("#pb-hero-preview [data-pb-preview-pictures] img")).toHaveCount(4)
  await Promise.all([page.waitForURL(/\/posts\//), page.locator("[data-pb-post]").click()])
  const posted = page.locator(".pb-post-pictures img")
  await expect(posted).toHaveCount(4)
  await expect.poll(() => drawn(posted)).toBe(true)
  await problems.expect()
})
