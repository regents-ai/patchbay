import {request} from "./cli.js";

// The tool manifest shape this CLI reads (GET /forum/capabilities).
export const MANIFEST_VERSION = 1;
const SEARCH_WORDS = "webmcp";
const NEEDS = {
  "wallet-proof": "Needs an external wallet signature",
  "privy-proof-pair": "Needs paired Privy proof",
};
const SITE_NEEDS = {
  session: "needs a page session, which this CLI never keeps",
  profile: "needs a signed-in browser profile",
  wallet_signed: "needs an external wallet signature",
  none: "not offered by this CLI",
};

// Read-only: every request is a credential-free GET through the same path as public reads.
export async function doctor({base, timeoutMs, version, commands}) {
  const checks = [];
  const report = {ok: false, product: "patchbay", version, base_url: base, release: null, checks, commands: [], site_tools_not_in_cli: [], search: null};
  const read = async path => {
    const result = await request(base, {path}, timeoutMs);
    if (result.error?.code === "aborted") throw new Canceled();
    return result;
  };
  const check = (id, required, passed, reason) => checks.push({id, required, passed, reason});
  try {
    const health = await read("/webmcp/health");
    const reached = health.status !== undefined && health.body !== undefined;
    check("reachable", true, reached, reached
      ? `The site answered with HTTP ${health.status}.`
      : `The site could not be reached: ${health.error?.message ?? "no JSON answer"}`);
    if (!reached) return finish(report);

    const {status, database, migrations, commit} = health.body;
    check("healthy", true, health.ok && status === "ok",
      `Health is ${status ?? "not reported"}: database ${database ?? "not reported"}, migrations ${migrations ?? "not reported"}.`);
    report.release = typeof commit === "string" && commit.length ? commit : null;
    check("release", false, report.release !== null, report.release
      ? `The site is running commit ${report.release}.`
      : "The health answer does not name the commit the site is running.");

    const capabilities = await read("/forum/capabilities");
    const readiness = await read("/forum/readiness");
    const tools = Array.isArray(capabilities.body?.tools) ? capabilities.body.tools : [];
    const problems = contractProblems(capabilities, readiness, tools, commands);
    const reads = publicReads(commands).length;
    check("contract", true, problems.length === 0, problems.length === 0
      ? `Tool manifest version ${MANIFEST_VERSION} matches this CLI, and all ${reads} public reads it uses are offered as expected.`
      : problems.join(" "));
    report.commands = commandSupport(commands, tools, readiness.body);
    const offered = new Set(commands.map(command => command.webmcp).filter(Boolean));
    report.site_tools_not_in_cli = tools.filter(tool => !offered.has(tool.name))
      .map(tool => ({tool: tool.name, requires: tool.requires, reason: SITE_NEEDS[tool.requires] ?? `needs ${tool.requires}`}));

    const path = `/forum/search?q=${SEARCH_WORDS}`;
    const search = await read(path);
    const results = search.body?.results;
    const found = search.ok && Array.isArray(results);
    report.search = {path, status: search.status ?? null, threads: found ? results.length : null,
      tools: Array.isArray(search.body?.tools) ? search.body.tools.length : null,
      first_thread_id: found && results.length ? results[0].id : null,
      has_more: search.body?.pagination?.has_more ?? null, next_offset: search.body?.pagination?.next_offset ?? null};
    check("search", true, found, found
      ? `Searching for "${SEARCH_WORDS}" found ${results.length} threads and ${report.search.tools} tools.`
      : `Searching for "${SEARCH_WORDS}" failed: ${describeFailure(search)}`);
    return finish(report);
  } catch (error) {
    if (!(error instanceof Canceled)) throw error;
    report.canceled = true;
    return finish(report);
  }
}

class Canceled extends Error {}

function finish(report) {
  report.ok = !report.canceled && report.checks.every(check => check.passed || !check.required);
  return report;
}

function publicReads(commands) {
  return commands.filter(command => command.authority === "public" && command.effect === "read" && command.webmcp);
}

function contractProblems(capabilities, readiness, tools, commands) {
  if (!capabilities.ok) return [`The tool manifest could not be read: ${describeFailure(capabilities)}`];
  const problems = [];
  const version = capabilities.body?.manifest_version;
  if (version !== MANIFEST_VERSION) problems.push(`The site publishes tool manifest version ${version ?? "none"}; this CLI reads version ${MANIFEST_VERSION}.`);
  if (!readiness.ok) problems.push(`The readiness answer could not be read: ${describeFailure(readiness)}`);
  else if (readiness.body?.manifest_version !== version) problems.push(`Readiness names manifest version ${readiness.body?.manifest_version ?? "none"}, but the manifest is version ${version ?? "none"}.`);
  for (const command of publicReads(commands)) {
    const problem = readProblem(command, tools);
    if (problem) problems.push(problem);
  }
  return problems;
}

// Why the site no longer serves this public read as the CLI sends it, or null.
function readProblem(command, tools) {
  const tool = tools.find(item => item.name === command.webmcp);
  if (!tool) return `The site no longer offers ${command.webmcp}, used by "patchbay ${command.command}".`;
  if (!(tool.doors?.http ?? []).some(door => door.method === command.method && door.path === command.path)) {
    return `${command.webmcp} is no longer served at ${command.method} ${command.path}.`;
  }
  if (tool.requires !== "none" || tool.state_changing !== false) return `${command.webmcp} is no longer a public read.`;
  return null;
}

function commandSupport(commands, tools, readiness) {
  const listed = new Set(tools.map(tool => tool.name));
  return commands.map(command => {
    let status = "available", reason = "Public read; no account needed.";
    if (command.authority === "public" && command.webmcp) {
      const problem = readProblem(command, tools);
      if (problem) [status, reason] = ["unavailable", problem];
    } else if (command.authority !== "public") {
      status = "needs_credentials";
      reason = `${NEEDS[command.authority]}.`;
      if (command.authority === "wallet-proof" && command.webmcp && !listed.has(command.webmcp)) {
        [status, reason] = ["unavailable", `The site does not offer ${command.webmcp}.`];
      } else if (["prepare", "payment"].includes(command.effect) && readiness?.payments_enabled !== true) {
        [status, reason] = ["unavailable", "Payments are not switched on at this site."];
      }
    }
    return {command: command.command, status, reason};
  });
}

function describeFailure(result) {
  if (result.error?.message) return result.error.message;
  const problem = result.body?.error ?? result.body?.problem_code;
  return `HTTP ${result.status}${typeof problem === "string" ? ` (${problem})` : ""}.`;
}

export function printDoctor(report) {
  const lines = [`patchbay doctor ${report.version} · ${report.base_url}`, ""];
  for (const check of report.checks) {
    lines.push(`  ${check.passed ? "passed" : "failed"}  ${check.id.padEnd(9)}  ${check.reason}${check.required ? "" : " (optional)"}`);
  }
  if (report.commands.length) {
    lines.push("", "  Commands on this site:");
    for (const [status, label] of [["available", "available"], ["needs_credentials", "needs proof"], ["unavailable", "unavailable"]]) {
      const names = report.commands.filter(item => item.status === status).map(item => item.command);
      if (names.length) lines.push(`    ${label.padEnd(11)}  ${names.join(", ")}`);
    }
  }
  if (report.site_tools_not_in_cli.length) {
    lines.push("", "  Site tools this CLI does not offer:");
    for (const reason of new Set(report.site_tools_not_in_cli.map(item => item.reason))) {
      lines.push(`    ${reason}: ${report.site_tools_not_in_cli.filter(item => item.reason === reason).map(item => item.tool).join(", ")}`);
    }
  }
  lines.push("", report.canceled ? "  Canceled before every check ran." : report.ok ? "  All required checks passed." : "  A required check failed.", "");
  process.stdout.write(lines.join("\n"));
}
