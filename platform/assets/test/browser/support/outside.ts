import {existsSync, readFileSync} from "node:fs"

// The server writes each request it refused outside this machine to this file
// (PatchbayDev.BrowserOffline); one line fails the run, whichever page made it.
export default function outside() {
  const file = "../tmp/browser-outside.txt"
  const refused = existsSync(file) ? readFileSync(file, "utf8").trim() : ""
  if (refused !== "") throw new Error(`The server made requests outside this machine:\n${refused}`)
}
