// ExUnit's cross-process journey feeds a line to this harness; credentials never
// enter command arguments or temporary files. The installed CLI still reads stdin.
import {createInterface} from "node:readline";
import {spawnSync} from "node:child_process";
import {fileURLToPath} from "node:url";
const lines = createInterface({input: process.stdin});
lines.once("line", line => {
  const {args, input} = JSON.parse(line);
  const result = spawnSync(process.execPath, [fileURLToPath(new URL("../bin/patchbay.js", import.meta.url)), ...args], {
    input: input === null ? "" : JSON.stringify(input), encoding: "utf8", timeout: 15000,
    env: {...process.env, PATCHBAY_BASE_URL: "https://ambient-untrusted.invalid"},
  });
  process.stdout.write(result.stdout || JSON.stringify({ok: false, error: {code: "fixture_cli_failed"}}));
  lines.close(); process.stdin.destroy();
});
