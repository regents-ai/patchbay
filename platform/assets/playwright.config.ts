import {execFileSync} from "node:child_process"
import {defineConfig, devices} from "@playwright/test"

// A port free on this machine, chosen once per run. The test workers read it
// from the environment the runner hands them.
process.env.PATCHBAY_BROWSER_PORT ??= execFileSync(process.execPath, [
  "-e",
  "const s = require('net').createServer().listen(0, '127.0.0.1', () => { process.stdout.write(String(s.address().port)); s.close() })",
]).toString()

const port = process.env.PATCHBAY_BROWSER_PORT
const baseURL = `http://127.0.0.1:${port}`

// The pages as a person sees them, in Chromium, at 1280 with a mouse and at
// 390 as a phone with touch. The server is this checkout's, built here, over
// the test database, and it keeps nothing it writes (PatchbayDev.BrowserDatabase).
export default defineConfig({
  testDir: "./test/browser",
  fullyParallel: false,
  workers: 1,
  forbidOnly: true,
  retries: 0,
  reporter: "line",
  use: {
    baseURL,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  webServer: {
    command: [
      "mix do ecto.create --quiet + shared_account_table.create + regent_identity.migrate + ecto.migrate --quiet + assets.build",
      "PATCHBAY_BROWSER_TEST=1 mix phx.server",
    ].join(" && "),
    cwd: "..",
    env: {MIX_ENV: "test", PORT: port},
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
