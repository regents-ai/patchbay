import assert from "node:assert/strict";
import {test} from "node:test";
import {fileURLToPath} from "node:url";
import {fixture, invoke} from "./helpers.js";
import {buildForumTools} from "../../platform/assets/js/webmcp/forum_tools.js";

const bin = fileURLToPath(new URL("../bin/patchbay.js", import.meta.url));

test("public CLI reads match existing browser tools, including complete cursor pages", async t => {
  const api = await fixture(t);
  const tools = buildForumTools({fetch: (path, options) => fetch(new URL(path, api.origin), options)});
  const cursor = "SFMyNTY.cursor/bytes+資料==";
  const cases = [
    {tool: "get_tool_history", input: {origin: "shop.example", tool_name: "checkout", after: cursor, limit: 1}, args: ["tools", "history", "--origin", "shop.example", "--tool-name", "checkout", "--after", cursor, "--limit", "1"], field: "history", body: {origin: "shop.example", tool_name: "checkout", versions: [{id: "v1", contract_sha256: "a".repeat(64), input_schema: {description: "資料🌳".repeat(5000)}}], pagination: {has_more: true, next_cursor: cursor}}},
    {tool: "search_threads", input: {q: "cart 資料", origin: "shop.example", tool_name: "add_to_cart", since_minutes: 60, offset: 20}, args: ["reports", "search", "--query", "cart 資料", "--origin", "shop.example", "--tool-name", "add_to_cart", "--since-minutes", "60", "--offset", "20"], field: "results", body: {tools: [], results: [{id: "thread-id"}], pagination: {has_more: true, next_offset: 40}}},
    {tool: "get_thread", input: {thread_id: "report-id"}, args: ["reports", "get", "report-id"], field: "thread", body: {report: {id: "report-id", quoted_note: "證據🌳".repeat(150)}, replies: [{id: "one", quoted_note: "whole reply", author: null}], pagination: {has_more: true, next_cursor: cursor}}},
    {tool: "get_thread", input: {thread_id: "report-id", after: cursor}, args: ["reports", "get", "report-id", "--after", cursor], field: "thread", body: {report: {id: "report-id"}, replies: [{id: "two", quoted_note: "final reply"}], pagination: {has_more: false, next_cursor: null}}},
    {tool: "get_agent_profile", input: {profile_id: "agent-id"}, args: ["agents", "get", "agent-id"], field: "author", body: {profile_id: "agent-id", agent_name: "雪", human_name: null, profile_url: "/agents/agent-id", can_receive_usdc: true, bounties_posted: 1, answers_accepted: 0, tips_given: 1, tips_given_usdc: "999999999999999999.000001", tips_received: 0, tips_received_usdc: "0.000000"}},
  ];
  for (const item of cases) {
    api.respond({status: 200, body: item.body});
    const browser = JSON.parse(await tools.find(tool => tool.name === item.tool).execute(item.input));
    const result = await invoke(bin, [...item.args, "--base-url", api.origin]);
    assert.equal(result.code, 0);
    assert.deepEqual(result.json.body, item.body);
    assert.deepEqual(result.json.body, browser[item.field]);
    const [browserRequest, cliRequest] = api.requests.slice(-2);
    assert.equal(cliRequest.path, browserRequest.path);
    assert.equal(cliRequest.method, browserRequest.method);
    assert.equal(cliRequest.headers.cookie, undefined);
  }
  api.respond({status: 400, body: {problem_code: "invalid_cursor", error: "Cursor expired"}});
  const browser = JSON.parse(await tools.find(tool => tool.name === "get_thread").execute({thread_id: "report-id", after: cursor}));
  const result = await invoke(bin, ["reports", "get", "report-id", "--after", cursor, "--base-url", api.origin]);
  assert.equal(result.code, 1);
  assert.equal(result.json.body.problem_code, browser.problem_code);
});
