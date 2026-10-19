import {execFileSync} from "node:child_process"
import {createHash} from "node:crypto"
import {resolve} from "node:path"
import {defineConfig, devices} from "@playwright/test"

// A port free on this machine, chosen once per run. The test workers read it
// from the environment the runner hands them.
process.env.PATCHBAY_BROWSER_PORT ??= execFileSync(process.execPath, [
  "-e",
  "const s = require('net').createServer().listen(0, '127.0.0.1', () => { process.stdout.write(String(s.address().port)); s.close() })",
]).toString()

const port = process.env.PATCHBAY_BROWSER_PORT
const baseURL = `http://127.0.0.1:${port}`

// The run's database is named after this checkout, so runs from two checkouts
// at once never wait on each other's sites.
const checkout = createHash("sha256").update(resolve("..")).digest("hex").slice(0, 8)
const partition = `${process.env.MIX_TEST_PARTITION ?? ""}_browser_${checkout}`

// The pages as a person sees them, in Chromium, at 1280 with a mouse and at
// 390 as a phone with touch. WebKit is not run on the Mac. The server is this
// checkout's, built here, over its own test database, and it keeps nothing it
// writes (PatchbayDev.BrowserDatabase). It gets nothing from the shell beyond
// what it needs to run (test/browser/support/server.ts). Neither the browser nor the server
// leaves this machine: the browser's outside requests fail the check that made
// them (test/browser/support/walk.ts), and the server's are refused and fail the
// run at its end (PatchbayDev.BrowserOffline, test/browser/support/outside.ts).
export default defineConfig({
  testDir: "./test/browser",
  fullyParallel: false,
  workers: 1,
  forbidOnly: true,
  retries: 0,
  reporter: "line",
  globalTeardown: "./test/browser/support/outside.ts",
  use: {
    baseURL,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  webServer: {
    command: "node test/browser/support/server.ts",
    env: {MIX_ENV: "test", MIX_TEST_PARTITION: partition, PORT: port},
    url: `${baseURL}/`,
    reuseExistingServer: false,
    timeout: 300_000,
  },
  projects: [
    {
      name: "1280",
      use: {...devices["Desktop Chrome"], viewport: {width: 1280, height: 900}},
    },
    {
      name: "390",
      use: {...devices["Pixel 7"], viewport: {width: 390, height: 844}},
    },
  ],
})
