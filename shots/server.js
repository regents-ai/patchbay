// Takes a picture of a public web page for Patchbay's gallery cards.
//
// POST /shot with {"url": "https://..."} answers with a WebP picture of the
// page at 1600×1000, or an error status. Pictures are taken one at a time.
// This machine holds no keys, and start.sh stops the browser from reaching
// anything but public addresses.

import http from "node:http";
import puppeteer from "puppeteer-core";

const PORT = 8080;
const WIDTH = 1600;
const HEIGHT = 1000;
const LOAD_TIMEOUT_MS = 25_000;
// Time for late fonts, images and cookie banners to settle after the load.
const SETTLE_MS = 1_500;
const MAX_BODY_BYTES = 4_096;

const browser = await puppeteer.launch({
  executablePath: "/usr/bin/chromium",
  pipe: true,
  args: ["--disable-dev-shm-usage", "--hide-scrollbars", "--mute-audio"],
});

// A browser that has gone away takes no more pictures; the machine restarts.
browser.on("disconnected", () => process.exit(1));

let queue = Promise.resolve();

// Runs `work` after every picture asked for before it.
function inTurn(work) {
  const turn = queue.then(work);
  queue = turn.catch(() => {});
  return turn;
}

async function shoot(url) {
  const context = await browser.createBrowserContext();

  try {
    const page = await context.newPage();
    await page.setViewport({ width: WIDTH, height: HEIGHT });
    await page.goto(url, { waitUntil: "load", timeout: LOAD_TIMEOUT_MS });
    await new Promise((resolve) => setTimeout(resolve, SETTLE_MS));
    return await page.screenshot({ type: "webp", quality: 80 });
  } finally {
    await context.close();
  }
}

function pageUrl(body) {
  const { url } = JSON.parse(body);
  const parsed = new URL(url);
  if (parsed.protocol !== "https:") throw new Error("not https");
  return parsed.href;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => {
      body += chunk;
      if (body.length > MAX_BODY_BYTES) reject(new Error("too large"));
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

const server = http.createServer(async (req, res) => {
  if (req.method !== "POST" || req.url !== "/shot") {
    res.writeHead(404).end();
    return;
  }

  let url;
  try {
    url = pageUrl(await readBody(req));
  } catch {
    res.writeHead(400).end();
    return;
  }

  try {
    const image = await inTurn(() => shoot(url));
    res.writeHead(200, { "content-type": "image/webp", "content-length": image.length });
    res.end(image);
  } catch (error) {
    console.error(`no picture of ${url}: ${error.message}`);
    res.writeHead(502).end();
  }
});

server.listen(PORT, "::", () => console.log(`taking pictures on port ${PORT}`));
