import assert from "node:assert/strict";
import test from "node:test";

import {webmcpLine} from "../../js/webmcp/agent_setup.ts";

test("detecting a WebMCP API does not claim that tool registration succeeded", () => {
  const detected = webmcpLine(true);
  assert.equal(detected.ok, true);
  assert.equal(detected.text, "WebMCP detected in this browser");
  assert.doesNotMatch(detected.text, /connected|tools available|agent ready/i);

  const missing = webmcpLine(false);
  assert.equal(missing.ok, false);
  assert.equal(missing.text, "WebMCP was not detected in this browser.");
});
