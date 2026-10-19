import {defineConfig, devices} from "@playwright/test"

// The browser walk (make check-browser). It starts its own local server on its own
// database, patchbay_dev_browser, and signs its people in first
// (test/browser/support/sign_in.exs). Chromium only: WebKit is not run on the Mac.
const port = 4099
const baseURL = `http://127.0.0.1:${port}`

export default defineConfig({
  testDir: "./test/browser",
  fullyParallel: true,
  workers: 3,
  forbidOnly: true,
  retries: 0,
  reporter: "line",
  use: {baseURL, trace: "retain-on-failure"},
  webServer: {
    command:
      "cd .. && " +
      `export PATCHBAY_DEV_PARTITION=_browser PORT=${port} POOL_SIZE=3 PRIVY_APP_ID=browser-walk-app && ` +
      'export PRIVY_VERIFICATION_KEY="$(openssl ecparam -name prime256v1 -genkey 2>/dev/null | openssl ec -pubout 2>/dev/null)" && ' +
      "mix ecto.setup > /dev/null && mix run assets/test/browser/support/sign_in.exs && mix phx.server",
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
