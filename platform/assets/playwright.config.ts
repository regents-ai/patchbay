import {execFileSync} from "node:child_process"
import {defineConfig, devices} from "@playwright/test"

// The browser walk (make check-browser). It builds the pages' scripts and styles,
// starts its own local server on a database made for this run, signs its people in
// first (test/browser/support/serve.sh), and drops the database at the end, whether
// the server never started (serve.sh) or the walk ran (test/browser/support/teardown.ts). Chromium only: WebKit is not run on the Mac.
// Neither the browser nor the server leaves this machine: the browser's outside
// requests fail the check that made them (test/browser/support/test.ts), and the
// server, with the outside services' settings cleared, refuses its own and the walk
// fails at the end (config/dev.exs, test/browser/support/teardown.ts).
// Each run takes a port nothing on this machine is using and names its database,
// saved sign-ins, outside-request list and failed checks' traces after it
// (patchbay_dev_browser_<port>, test-results/_browser_<port>), so two walks at once,
// even in one checkout, never reach each other's server, data or files. The workers
// read this file again and keep the run's port from the environment they inherit.
process.env.PATCHBAY_WALK_PORT ??= execFileSync(process.execPath, [
  "-e",
  "const s = require('node:net').createServer().listen(0, '127.0.0.1', () => { console.log(s.address().port); s.close() })",
]).toString().trim()
const port = Number(process.env.PATCHBAY_WALK_PORT)
process.env.PATCHBAY_DEV_PARTITION = `_browser_${port}`
const baseURL = `http://127.0.0.1:${port}`

export default defineConfig({
  testDir: "./test/browser",
  fullyParallel: true,
  workers: 3,
  forbidOnly: true,
  retries: 0,
  reporter: "line",
  globalTeardown: "./test/browser/support/teardown.ts",
  outputDir: `test-results/${process.env.PATCHBAY_DEV_PARTITION}`,
  use: {baseURL, trace: "retain-on-failure"},
  webServer: {
    command: `PORT=${port} test/browser/support/serve.sh`,
    url: `${baseURL}/webmcp/health`,
    reuseExistingServer: false,
    timeout: 300_000,
  },
  projects: [
    // Specs named *.desktop.spec.ts run only on the desktop, *.phone.spec.ts only on
    // the phones, and the rest on all three.
    {
      name: "desktop",
      testIgnore: /\.phone\.spec\.ts$/,
      use: {...devices["Desktop Chrome"], viewport: {width: 1280, height: 900}},
    },
    // Touch phones: a Pixel 7 at 390 wide, and the same at 320.
    {
      name: "phone",
      testIgnore: /\.desktop\.spec\.ts$/,
      use: {...devices["Pixel 7"], viewport: {width: 390, height: 844}},
    },
    {
      name: "small phone",
      testIgnore: /\.desktop\.spec\.ts$/,
      use: {...devices["Pixel 7"], viewport: {width: 320, height: 640}},
    },
  ],
})
