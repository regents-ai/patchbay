import {execFileSync} from "node:child_process"
import {existsSync, readFileSync} from "node:fs"

// The end of every walk that got its server up, passed or failed. Playwright stops
// the server without waiting for it, so the run's database is dropped here
// (drop.exs); serve.sh drops it when the server never starts. Then each request the
// walk's server refused outside this machine, written to this file by
// PatchbayDev.WalkOffline, fails the walk, whichever page caused it.
export default function teardown() {
  execFileSync("mix", ["run", "--no-start", "assets/test/browser/support/drop.exs"], {
    cwd: "..",
    stdio: "inherit",
  })

  const file = "../tmp/walk-outside.txt"
  const outside = existsSync(file) ? readFileSync(file, "utf8").trim() : ""
  if (outside !== "")
    throw new Error(`The walk's server made requests outside this machine:\n${outside}`)
}
