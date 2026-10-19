import {spawn} from "node:child_process"
import {mkdirSync, rmSync} from "node:fs"

// The browser tests' server, started with only what it needs from the shell
// that ran them: the tools on the PATH, the home folder and the local database
// login. Anything else there, such as a chain node's address or a signing key,
// never reaches it.
const SHELL = ["PATH", "HOME", "USER", "LANG", "LC_ALL", "TMPDIR", "MIX_HOME", "HEX_HOME"]
const DATABASE = ["PATCHBAY_DB_USERNAME", "PATCHBAY_DB_PASSWORD", "PATCHBAY_DB_HOST"]

const env = Object.fromEntries(
  [...SHELL, ...DATABASE, "MIX_ENV", "MIX_TEST_PARTITION", "PORT"].flatMap(name =>
    process.env[name] === undefined ? [] : [[name, process.env[name]!]],
  ),
)

// This run's list of requests the server refused (PatchbayDev.BrowserOffline).
mkdirSync("../tmp", {recursive: true})
rmSync(`../tmp/browser-outside-${env.PORT}.txt`, {force: true})

const server = spawn(
  "mix do ecto.setup + assets.build + esbuild patchbay_payments_lab && PATCHBAY_BROWSER_TEST=1 mix phx.server",
  {cwd: "..", env, shell: "/bin/sh", stdio: "inherit"},
)
server.on("exit", code => process.exit(code ?? 1))
