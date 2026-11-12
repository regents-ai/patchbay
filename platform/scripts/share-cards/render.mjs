// Draws the share pictures from card.html in headless Chromium, 1200 by 630,
// one for each address (PatchbayWeb.SiteEdition.share_picture/1). They differ
// only in the words beside the mark:
//
//   priv/static/images/og-image.png        patchbay.help
//   priv/static/images/og-image-open.png   the open address, which names no other
//
// Run after `mix deps.get` in platform/ (the font comes from regent_ui) and
// `npm ci` in platform/assets (Playwright):
//   node platform/scripts/share-cards/render.mjs
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const platform = join(here, "..", "..");
const { chromium } = createRequire(join(platform, "assets", "package.json"))("@playwright/test");

const pictures = [
  { label: "patchbay.help", file: "og-image.png" },
  { label: "patchbay", file: "og-image-open.png" },
];

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });

for (const { label, file } of pictures) {
  const url = pathToFileURL(join(here, "card.html"));
  url.search = new URLSearchParams({ label }).toString();
  await page.goto(url.href);
  await page.waitForFunction(() => [...document.images].every((img) => img.complete && img.naturalWidth > 0));

  const font = await page.evaluate(async () => {
    await document.fonts.ready;
    return [...document.fonts].every((face) => face.status === "loaded");
  });
  if (!font) throw new Error("Geist Serif did not load: run `mix deps.get` in platform/ first.");

  await page.screenshot({ path: join(platform, "priv", "static", "images", file) });
}

await browser.close();
