import {execFileSync} from "node:child_process"
import {defineConfig, devices} from "@playwright/test"

// The browser walk (make check-browser). It builds the pages' scripts and styles,
// starts its own local server on a database made for this run, signs its people in
// first (test/browser/support/sign_in.exs), and drops the database at the end
// (test/browser/support/teardown.ts). Chromium only: WebKit is not run on the Mac.
// Neither the browser nor the server leaves this machine: the browser's outside
// requests fail the check that made them (test/browser/support/test.ts), and the
// server, with the outside services' settings cleared, refuses its own and the walk
// fails at the end (config/dev.exs, test/browser/support/teardown.ts).
// Each run takes a port nothing on this machine is using and names its database
// after it, patchbay_dev_browser_<port>, so two walks at once never reach each
// other's server or data. The workers read this file again and keep the run's port
// from the environment they inherit.
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
  use: {baseURL, trace: "retain-on-failure"},
  webServer: {
    command:
      "cd .. && mkdir -p tmp && rm -f tmp/walk-outside.txt && " +
      "unset BASE_RPC_URL PATCHBAY_ETHEREUM_NODE_URL ETHEREUM_READ_RPC_URL PATCHBAY_SIWA_URL " +
      "SIWA_HOSTED_URL SIWA_HOSTED_SIGNING_KEY SIWA_ACTIVITY_READ_TOKEN OPENROUTER_API_KEY && " +
      `export PATCHBAY_WALK=true PORT=${port} POOL_SIZE=3 PRIVY_APP_ID=browser-walk-app && ` +
      'export PRIVY_VERIFICATION_KEY="$(openssl ecparam -name prime256v1 -genkey 2>/dev/null | openssl ec -pubout 2>/dev/null)" && ' +
      "mix ecto.setup > /dev/null && mix run assets/test/browser/support/sign_in.exs && " +
      "mix assets.build > /dev/null && mix phx.server",
    url: `${baseURL}/webmcp/health`,
    reuseExistingServer: false,
    timeout: 300_000,
  },
  projects: [
    {name: "desktop", use: {...devices["Desktop Chrome"], viewport: {width: 1280, height: 900}}},
    {name: "phone", use: {...devices["Desktop Chrome"], viewport: {width: 390, height: 844}}},
    {name: "small phone", use: {...devices["Desktop Chrome"], viewport: {width: 320, height: 640}}},
  ],
})
