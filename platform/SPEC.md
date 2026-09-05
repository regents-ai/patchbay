# Patchbay v0 Technical Specification

**Product:** Patchbay
**Hackathon workflow:** Skill Uplift Studio
**Primary stack:** Elixir, Phoenix, LiveView, Ash Framework, AshPostgres
**Browser integration:** Imperative WebMCP API through a small JavaScript island
**Model integration:** OpenAI Responses API
**Status:** Build specification for the WebMCP Challenge submission
**Scope:** One flawless failure → repair → hot-swap → retry → verification loop

---

## 1. Product definition

Patchbay is a browser-native repair system for WebMCP tools.

A website exposes a WebMCP tool. A browser agent invokes it. Patchbay records the exact tool revision, structured arguments, handler result, and visible page state before and after execution. When the tool reports success but fails to complete the visible user goal, Patchbay:

1. Identifies the failed postcondition.
2. Produces a bounded repair proposal.
3. Tests the proposed behavior against a deterministic canary.
4. Shows the owner the exact contract and behavior changes.
5. Waits for human approval.
6. Retires the defective WebMCP tool.
7. Registers a versioned replacement in the same document.
8. Observes the browser’s `toolchange` lifecycle.
9. Lets the same browser agent retry the original goal.
10. Verifies completion from visible page state.

The hackathon’s seeded workflow is **Skill Uplift Studio**:

```text
Human opens a SKILL.md in the page
→ browser agent invokes uplift_current_skill_v1
→ OpenAI generates a candidate
→ v1 reports success but does not update the Candidate editor
→ Patchbay rejects the false completion
→ a repair changes the handler contract
→ human approves the repair
→ v1 is retired
→ uplift_current_skill_v2 is registered
→ browser observes toolchange
→ same agent retries
→ candidate appears in the visible editor
→ Patchbay verifies the goal
```

## The generated Skill is a candidate revision, not a measured performance improvement. Patchbay verifies the website tool’s browser-side contract; it does not claim that the rewritten Skill improves an agent on held-out tasks. This preserves the broader Techtree distinction between an artifact, evidence about the artifact, and a commercial claim.

## 2. Why WebMCP is essential

WebMCP lets a page register JavaScript-backed tools with names, natural-language descriptions, structured input schemas, execution callbacks, and safety annotations. Registered tools live in the active `Document`, and the current draft defines dynamic registration, removal through `AbortSignal`, and the `toolchange` event. The browser agent’s observation timing remains implementation-defined, so Patchbay must verify registration locally and may explicitly ask the same agent to reinspect current tools after a change. WebMCP is presently a Community Group draft rather than a W3C standard.

Patchbay relies on four WebMCP properties:

```text
Structured invocation evidence
    tool name + exact revision + schema + arguments + result

Shared browser state
    human, page, and agent operate in the same active document

Dynamic tool lifecycle
    defective revision can be removed and a corrected revision registered

Visible completion
    the application can compare declared success with actual UI side effects
```

Chrome’s WebMCP guidance explicitly recommends testing tool logic, returned information, intended UI updates, side effects, tool selection, arguments, and complete user journeys. Patchbay turns those principles into a live product rather than an offline test suite.

---

## 3. Binding v0 scope

### 3.1 Required

Patchbay v0 must provide:

* One public seeded room.
* One pasted or uploaded Markdown Skill.
* One Source editor.
* One Candidate editor.
* One deliberately defective WebMCP tool.
* Structured invocation evidence.
* Deterministic visible-state verification.
* One OpenAI-generated repair proposal.
* A safe declarative repair language.
* One deterministic canary.
* Human approval.
* Actual WebMCP unregistration and versioned re-registration.
* A visible `toolchange` observation.
* Same-page, same-browser-session retry.
* One-click demo reset.
* A final verified-success state.
* A complete event timeline.

### 3.2 Explicit non-goals

Do not include:

```text
x402 or real payment
Modal execution
SkillSpector
SkillEvaluator
SkillOpt
A/B task evaluation
multiple harnesses
arbitrary website integration
model-generated JavaScript
eval() or dynamic script injection
arbitrary repair code
multiple resident agents
critic or adjudicator agents
public rooms
accounts or teams
GitHub import
ZIP upload
marketplace listings
service deployment
reputation
onchain receipts
MCP hosting
```

The public hackathon build must remain free for judging. The rules require a live URL, public open-source repository, visible license, and a demonstration video shorter than three minutes; judging weighs WebMCP leverage, execution, impact, and creativity equally.

---

## 4. Technical architecture

```text
┌──────────────────────────────── Browser document ────────────────────────────────┐
│                                                                                  │
│  Source editor             Candidate editor            Patchbay timeline         │
│       │                           ▲                            ▲                   │
│       │                           │ LiveView patch             │ LiveView patch    │
│       ▼                           │                            │                   │
│  ┌───────────────────────────────────────────────────────────────────────────┐   │
│  │ WebMCP JavaScript island                                                 │   │
│  │                                                                           │   │
│  │ - owns document.modelContext registrations                               │   │
│  │ - owns AbortControllers                                                   │   │
│  │ - captures DOM state                                                      │   │
│  │ - wraps tool execution                                                    │   │
│  │ - observes toolchange                                                     │   │
│  │ - reconciles desired and observed tool sets                               │   │
│  └───────────────────────────────────────────────────────────────────────────┘   │
│                         │ LiveView pushEvent / handleEvent                         │
└─────────────────────────┼─────────────────────────────────────────────────────────┘
                          ▼
┌──────────────────────── Phoenix / LiveView ───────────────────────────────────────┐
│                                                                                   │
│  RoomLive.Show                                                                    │
│     │                                                                             │
│     ├── validates browser envelopes                                               │
│     ├── starts OpenAI tasks                                                       │
│     ├── publishes LiveView state                                                   │
│     ├── sends desired tool revisions to JS                                        │
│     └── renders owner approval and evidence                                       │
│                                                                                   │
│  Patchbay services                                                                │
│     ├── InvocationRunner                                                          │
│     ├── PostconditionVerifier                                                     │
│     ├── RepairPlanner                                                             │
│     ├── RepairPolicy                                                              │
│     ├── CanaryRunner                                                              │
│     ├── ToolPublisher                                                             │
│     └── DemoReset                                                                 │
│                                                                                   │
└───────────────────────────┬───────────────────────────────────────────────────────┘
                            ▼
┌──────────────────────── Ash domain / PostgreSQL ──────────────────────────────────┐
│ Room · BrowserSession · ToolRevision · Invocation · RepairProposal                 │
│ Verification · RoomEvent                                                          │
└───────────────────────────────────────────────────────────────────────────────────┘
                            │
                            ▼
                    OpenAI Responses API
              candidate generation + repair planning
```

### 4.1 Authority boundary

**Phoenix/Ash owns durable truth:**

* Desired active tool revision.
* Tool contracts.
* Room state.
* Source and candidate artifacts.
* Invocation evidence.
* Repair proposals.
* Human approvals.
* Verification results.
* Ordered event history.

**The JavaScript island owns ephemeral browser truth:**

* Which tools are actually registered in this document.
* The `AbortController` for each registration.
* Browser-session identity.
* Observed `toolchange` events.
* Current DOM values.
* Whether a particular UI revision has actually appeared.

A database row saying a tool is active does not prove that a browser registered it. Patchbay stores desired state server-side and stores separate browser observations.

---

## 5. Framework baseline

Integrate into the existing Phoenix/Ash site rather than creating a separate service. For a standalone build, the current stable package line as of August 31, 2026 is Phoenix 1.8.13, LiveView 1.2.11, Ash 3.32.1, AshPostgres 2.12, and AshPhoenix 2.3.24. Pin the exact compatible dependency graph in `mix.lock`.

Recommended dependencies:

```elixir
defp deps do
  [
    {:phoenix, "~> 1.8"},
    {:phoenix_live_view, "~> 1.2"},
    {:ash, "~> 3.32"},
    {:ash_postgres, "~> 2.12"},
    {:ash_phoenix, "~> 2.3"},
    {:postgrex, ">= 0.0.0"},
    {:req, ">= 0.0.0"},
    {:jason, "~> 1.4"}
  ]
end
```

Avoid additional state-machine, workflow, queue, and JavaScript-framework dependencies in the hackathon build.

AshPostgres is the authoritative data layer. AshPhoenix forms may be used for the editable room form, but ordinary LiveView events are acceptable for the highly interactive repair workflow. AshPhoenix’s supported form lifecycle is create, render, validate, and submit; LiveView hooks provide client/server interaction through `pushEvent` and `handleEvent`.

---

## 6. Routes

```elixir
scope "/webmcp", TechtreeWeb.WebMCP do
  pipe_through :browser

  live "/rooms/:slug", RoomLive.Show, :show
end
```

Required public demo URL:

```text
/webmcp/rooms/skill-uplift
```

**Amended 2026-09-01.** That address is an entrance rather than a room. It
creates or reopens the visitor's own room, remembers it for that browser, and
sends the visitor to `/webmcp/rooms/<generated address>`; an address that names
no room is not found. The number of rooms that can exist at once is bounded,
empty rooms that have sat idle are cleared away, and a visitor who arrives when
no room is free is asked to come back in a few minutes. Everything else in this
specification describes a single room and still holds room by room.

Optional diagnostic endpoint:

```text
GET /webmcp/health
```

Do not place owner approval on a separate route. The human, agent, active page, visible state, and WebMCP tool registry should remain in one document.

---

## 7. Ash domain

```elixir
defmodule Techtree.Patchbay do
  use Ash.Domain

  resources do
    resource Techtree.Patchbay.Room
    resource Techtree.Patchbay.BrowserSession
    resource Techtree.Patchbay.ToolRevision
    resource Techtree.Patchbay.Invocation
    resource Techtree.Patchbay.RepairProposal
    resource Techtree.Patchbay.Verification
    resource Techtree.Patchbay.RoomEvent
  end
end
```

Expose a small code interface rather than calling generic Ash actions from LiveView. Current Ash code interfaces generate application-facing functions around resource actions and should be the normal boundary used by `RoomLive.Show`.

---

## 8. Resource model

### 8.1 `Room`

Represents one human-agent repair room. Amended 2026-09-01: a room belongs to
the browser session that opened it rather than being shared by everyone; see
the amendment in section 6.

```text
id                         UUID primary key
slug                       unique string
title                      string
status                     enum
goal_kind                  enum: skill_uplift
goal_text                  string
source_markdown            sensitive text
source_sha256              64-character hex
candidate_markdown         sensitive text, nullable
candidate_sha256           nullable
ui_revision                integer, default 0
desired_tool_generation    integer, default 1
seed_version               string
last_failed_invocation_id  nullable UUID
active_repair_proposal_id  nullable UUID
inserted_at
updated_at
```

Room statuses:

```text
ready
invoking
failed
diagnosing
repair_ready
awaiting_approval
publishing
repaired
retrying
verified
resetting
error
```

Actions:

```text
create_seeded_room
update_source
apply_candidate
record_failure
begin_diagnosis
mark_repair_ready
begin_publication
mark_repaired
mark_verified
reset_demo
```

Invariants:

* `source_markdown` is at most 65,536 UTF-8 bytes.
* `candidate_markdown` is at most 65,536 UTF-8 bytes.
* Every source or candidate update recalculates its SHA-256 digest.
* Applying a candidate increments `ui_revision`.
* Resetting restores the canonical fixture and generation 1.
* No action silently treats a candidate as task-evaluated.

### 8.2 `BrowserSession`

Represents one mounted browser tab, not an authenticated person or cryptographic agent identity.

```text
id                       UUID primary key
room_id                  relationship
client_instance_id       unique random UUID from sessionStorage
user_agent_digest        string
webmcp_supported         boolean
desired_generation       integer
observed_generation      nullable integer
observed_tool_names      array of strings
observed_contracts       map name → digest
toolchange_count         integer
connected_at
last_seen_at
disconnected_at
```

Patchbay may accurately claim:

```text
same room
same document lifecycle
same browser-session identifier
same visible conversation context
```

It must not claim that it cryptographically proved the same model instance.

### 8.3 `ToolRevision`

Immutable contract and behavior definition for one tool version.

```text
id                    UUID primary key
room_id               relationship
parent_revision_id    nullable relationship
generation            integer
name                  string
title                 string
description           text
input_schema          JSON map
annotations           JSON map
handler_adapter       enum
output_contract       JSON map
postcondition_set     enum
contract_sha256       hex digest
origin                enum: seed | repair_model | operator
status                enum
published_at          nullable
retired_at            nullable
inserted_at
```

Handler adapters:

```text
return_candidate_only
apply_candidate_to_editor
apply_candidate_and_show_diff
reject_on_invalid_frontmatter
return_structured_error
```

Revision statuses:

```text
candidate
canary_passed
ready_for_approval
approved
desired
observed_active
retired
rejected
failed
```

Rules:

* Contract fields are immutable after creation.
* A changed contract always creates a new revision.
* Tool names are versioned: `uplift_current_skill_v1`, `uplift_current_skill_v2`.
* Never unregister and immediately register a changed schema under the same name. The WebMCP draft notes that same-name rapid replacement is not protected from old-arguments/new-schema races.
* A partial unique index permits at most one desired active dynamic revision per room.
* `contract_sha256` is calculated from canonical JSON containing:

  * name;
  * title;
  * description;
  * input schema;
  * annotations;
  * handler adapter;
  * output contract;
  * postcondition set.

### 8.4 `Invocation`

Append-oriented evidence for a WebMCP call.

```text
id                        UUID primary key
request_uuid              unique UUID generated in browser
room_id                   relationship
browser_session_id        relationship
tool_revision_id          relationship
tool_contract_sha256      hex digest
arguments                 JSON map
arguments_sha256          hex digest
pre_state                 JSON map
handler_result            JSON map
handler_reported_success  boolean
generated_candidate       sensitive text, nullable
generated_candidate_sha256 nullable
generation_key            nullable hex digest
post_state                JSON map
effective_status          enum
failure_code              nullable enum
duration_ms               nullable integer
started_at
handler_returned_at
verified_at
```

Effective statuses:

```text
started
executing
handler_returned
awaiting_visible_state
verified_success
verified_failure
errored
cancelled
```

The `generation_key` is:

```text
SHA-256(source_sha256 + NUL + canonical_json(arguments))
```

A repaired tool may reuse a candidate generated by v1 only when the generation key is identical. This makes retry fast while preserving exact input binding.

### 8.5 `RepairProposal`

```text
id                         UUID primary key
room_id                    relationship
source_invocation_id       relationship
source_tool_revision_id    relationship
candidate_tool_revision_id nullable relationship
status                     enum
root_cause                 text
repair_plan                JSON map
contract_diff              JSON map
canary_result              JSON map
risk_notes                 array of strings
model                      string
model_response_id          string
prompt_version             string
input_sha256               hex digest
approved_by                nullable string
approved_at                nullable timestamp
rejected_at                nullable timestamp
published_at               nullable timestamp
inserted_at
```

Statuses:

```text
requested
generating
proposed
canary_running
canary_failed
ready_for_approval
approved
publishing
published
rejected
failed
```

Only a normal LiveView human action may move the proposal from `ready_for_approval` to `approved`.

No WebMCP tool may approve or publish a repair in v0.

### 8.6 `Verification`

```text
id                 UUID primary key
room_id            relationship
invocation_id      relationship
goal_kind          enum
checks              JSON map
passed              boolean
failure_code        nullable enum
expected_state      JSON map
observed_state      JSON map
inserted_at
```

### 8.7 `RoomEvent`

Append-only timeline event.

```text
id                   UUID primary key
room_id              relationship
browser_session_id   nullable relationship
sequence             bigint
kind                 enum
payload              JSON map
inserted_at
```

Required event kinds:

```text
room_reset
webmcp_supported
tool_registered
tool_unregistered
toolchange_observed
registry_reconciled
invocation_started
handler_returned
visible_state_observed
verification_passed
verification_failed
repair_requested
repair_proposed
canary_passed
canary_failed
approval_granted
approval_rejected
publication_requested
tool_revision_observed
goal_verified
platform_error
```

Use a per-room monotonic sequence or database-generated ordered key. The timeline should not be reconstructed solely from timestamps.

---

## 9. Seeded WebMCP tools

### 9.1 `get_patchbay_room_state`

Always registered.

```javascript
{
  name: "get_patchbay_room_state",
  title: "Read Patchbay room state",
  description:
    "Read the active Patchbay goal, visible editor state, current tool generation, " +
    "last verification, and whether an owner-approved repair is available.",
  inputSchema: {
    type: "object",
    properties: {},
    additionalProperties: false
  },
  annotations: {
    readOnlyHint: true,
    untrustedContentHint: false
  }
}
```

Returns:

```json
{
  "summary": "Room skill-uplift is failed at tool generation 1, and its last verification failed with VISIBLE_POSTCONDITION_NOT_MET.",
  "room": "skill-uplift",
  "goal": "Place an improved candidate in the visible Candidate editor.",
  "status": "failed",
  "desired_tool_generation": 1,
  "observed_tool_generation": 1,
  "source_sha256": "...",
  "candidate_sha256": null,
  "last_verification": {
    "passed": false,
    "failure_code": "VISIBLE_POSTCONDITION_NOT_MET"
  }
}
```

**Amended 2026-09-02.** The tool surface is what teaches a browser agent this
loop, so three things hold across every tool in this section and section 13.

Every result opens with a `summary`: one sentence, under 200 characters, saying
what happened, before any of the structure it describes. The example above shows
it; the other tools' results carry one in the same position.

Every description ends with the same sentence — "This page verifies tool results
against what is visible on screen; a mismatch can be reported with
report_tool_problem using the receipt from the result." — added by the page for
the permanent tools and by `RepairPolicy` for a repaired revision, which
measures the published description against its 1000-byte limit rather than the
model's half of it. The seeded `v1` description in 9.3 keeps its unqualified
promise: that promise is the defect the demo is about.

A failure is shaped like a success rather than a bare string:

```json
{
  "summary": "This call did not complete: this tool revision is no longer the one the page offers",
  "error_code": "REVISION_NOT_ACTIVE",
  "detail": "this tool revision is no longer the one the page offers",
  "retryable": true,
  "next_action": "Call get_patchbay_room_state to read the active tool, then call that one."
}
```

`error_code` is one of `BUSY`, `EXECUTION_CANCELLED`, `REVISION_NOT_ACTIVE`,
`INVALID_ARGUMENTS`, `UI_REVISION_TIMEOUT`, `PROOF_NOT_RECORDED`,
`INVOCATION_FAILED`, `SERVER_REFUSED`, `REPAIR_REQUEST_FAILED` or
`VERIFICATION_UNAVAILABLE`. A refusal from the report board instead carries
`problem_code` beside its plain `problem` text — `rate_limited`, `no_session`,
`invalid`, `not_found`, `unreachable`, or `receipt_missing`, `receipt_unknown`,
`receipt_wrong_identity`, `receipt_stale`, `receipt_spent` — named by the server
except `unreachable`, which is what the page says when the board never answered.

`report_tool_on_another_site` no longer asks for `contract_sha256` or
`arguments_sha256`. The agent sends the raw `arguments` object it passed, up to
8 KB, and the `tool_description` text it saw; the server digests both with
canonical JSON and SHA-256 and stores the results. A model cannot compute a
digest, and an invented one would be worthless. Reports about other sites remain
unverified by design.

### 9.2 `verify_skill_uplift_goal`

Always registered.

```javascript
{
  name: "verify_skill_uplift_goal",
  title: "Verify the visible Skill uplift",
  description:
    "Verify whether the visible Candidate editor contains a structurally valid " +
    "revision of the current Source Skill and whether the page-side goal was completed.",
  inputSchema: {
    type: "object",
    properties: {},
    additionalProperties: false
  },
  annotations: {
    readOnlyHint: true,
    untrustedContentHint: true
  }
}
```

### 9.3 `uplift_current_skill_v1`

Initial defective dynamic tool.

```javascript
{
  name: "uplift_current_skill_v1",
  title: "Improve the current Skill",
  description:
    "Improve the Skill currently loaded in the Source editor while preserving " +
    "its identity frontmatter, and place the revision in the visible Candidate editor.",
  inputSchema: {
    type: "object",
    required: ["instructions"],
    additionalProperties: false,
    properties: {
      instructions: {
        type: "string",
        minLength: 1,
        maxLength: 1000,
        description:
          "A bounded description of what should be clarified or improved."
      }
    }
  },
  annotations: {
    readOnlyHint: false,
    untrustedContentHint: true
  }
}
```

Behavior:

```text
handler_adapter = return_candidate_only
postcondition_set = skill_candidate_written_v1
```

The tool calls the trusted candidate generator and obtains a valid candidate. It returns a handler-level success but does not apply the candidate to page state.

### 9.4 `uplift_current_skill_v2`

Created after repair.

Behavior:

```text
handler_adapter = apply_candidate_to_editor
postcondition_set = skill_candidate_written_v1
```

Its output contract requires:

```json
{
  "reported_success": true,
  "applied": true,
  "verified": true,
  "candidate_sha256": "...",
  "ui_revision": 5,
  "change_summary": [],
  "warnings": [
    "This candidate has not been evaluated on task performance."
  ]
}
```

---

## 10. Visible-state contract

The Source and Candidate editors must have stable DOM identifiers:

```html
<textarea id="patchbay-source-editor"></textarea>
<textarea id="patchbay-candidate-editor" readonly></textarea>

<div
  id="patchbay-room-state"
  data-room-id="..."
  data-ui-revision="4"
  data-source-sha256="..."
  data-candidate-sha256=""
></div>
```

The browser snapshot contract is:

```json
{
  "room_id": "...",
  "ui_revision": 4,
  "source": {
    "present": true,
    "sha256": "...",
    "byte_length": 1882
  },
  "candidate": {
    "present": false,
    "sha256": null,
    "byte_length": 0
  }
}
```

Raw Skill text is sent to the server only as an internal trusted page-state envelope. It is not presented as an agent-controlled tool argument.

The browser computes digests using `crypto.subtle.digest("SHA-256", ...)`. The server independently recomputes them and rejects disagreement.

---

## 11. Postcondition set

`skill_candidate_written_v1` passes only when all checks pass:

```text
candidate_present
    Candidate editor contains non-whitespace text.

source_unchanged
    Post-state source digest equals pre-state source digest.

candidate_changed
    Candidate digest differs from source digest.

candidate_matches_server
    DOM candidate digest equals the candidate digest committed by Phoenix.

frontmatter_present
    Candidate begins with bounded YAML frontmatter.

frontmatter_parses
    Frontmatter parses through a safe, string-keyed parser.

identity_preserved
    Required `name` is unchanged.
    Existing `license` is unchanged.
    Existing author metadata is unchanged unless absent.

ui_revision_advanced
    Post-state revision is greater than pre-state revision.

tool_contract_current
    Invocation contract digest matches the active revision.

browser_session_current
    Post-state observation comes from the initiating browser session.
```

Failure codes:

```text
VISIBLE_POSTCONDITION_NOT_MET
SOURCE_CHANGED_DURING_INVOCATION
CANDIDATE_EMPTY
CANDIDATE_DIGEST_MISMATCH
FRONTMATTER_INVALID
IDENTITY_NOT_PRESERVED
STALE_TOOL_REVISION
STALE_BROWSER_SESSION
UI_REVISION_NOT_APPLIED
MODEL_GENERATION_FAILED
EXECUTION_CANCELLED
```

A raw handler result does not determine success. The effective result is:

```text
effective success = handler result is valid AND every required postcondition passes
```

---

## 12. WebMCP JavaScript island

File layout:

```text
assets/js/patchbay/
  webmcp_hook.js
  tool_registry.js
  invocation_bridge.js
  state_snapshot.js
  revision_waiter.js
  schemas.js
```

Register one LiveView hook:

```javascript
Hooks.PatchbayWebMCP = PatchbayWebMCP
```

Markup:

```heex
<div
  id={"patchbay-webmcp-#{@room.id}"}
  phx-hook="PatchbayWebMCP"
  phx-update="ignore"
  data-room-id={@room.id}
>
</div>
```

The island itself is ignored by LiveView patches. Source, candidate, timeline, and approval UI remain server-rendered outside the ignored node.

LiveView hooks can send events through `pushEvent`, receive server events through `handleEvent`, and react to mount, update, destroy, disconnect, and reconnect lifecycles. Server-pushed events are global to active hooks, so Patchbay event names must include or carry the room identifier.

### 12.1 Hook lifecycle

```javascript
const PatchbayWebMCP = {
  async mounted() {
    this.controllers = new Map()
    this.registeredDigests = new Map()
    this.waiters = new Map()
    this.browserSessionId = getOrCreateSessionId()
    this.onToolChange = event => this.reportToolChange(event)

    document.modelContext?.addEventListener(
      "toolchange",
      this.onToolChange
    )

    this.handleEvent(
      `patchbay:${this.el.dataset.roomId}:desired_toolset`,
      payload => this.reconcile(payload)
    )

    await this.bootstrap()
  },

  async reconnected() {
    await this.bootstrap()
  },

  disconnected() {
    this.reportDisconnected()
  },

  destroyed() {
    for (const controller of this.controllers.values()) {
      controller.abort()
    }

    document.modelContext?.removeEventListener(
      "toolchange",
      this.onToolChange
    )
  }
}
```

### 12.2 Bootstrap

```text
1. Feature-detect document.modelContext.
2. Generate or restore browserSessionId from sessionStorage.
3. Send browser and room identifiers to LiveView.
4. Receive the desired tool set from Phoenix.
5. Register missing tools.
6. Retire stale Patchbay-owned tools.
7. Call getTools() for local reconciliation.
8. Report observed names and contract digests.
```

Do not manipulate tools not owned by Patchbay.

Owned names are:

```text
get_patchbay_room_state
verify_skill_uplift_goal
uplift_current_skill_v*
```

### 12.3 Registry algorithm

```javascript
async function registerRevision(hook, revision) {
  const controller = new AbortController()

  const tool = buildToolDefinition(hook, revision)

  await document.modelContext.registerTool(tool, {
    signal: controller.signal
  })

  hook.controllers.set(revision.name, controller)
  hook.registeredDigests.set(
    revision.name,
    revision.contract_sha256
  )
}

function retireRevision(hook, name) {
  const controller = hook.controllers.get(name)

  if (controller) {
    controller.abort()
  }

  hook.controllers.delete(name)
  hook.registeredDigests.delete(name)
}
```

The `registerTool()` promise and `toolchange` event must both be recorded, but Patchbay must not rely on ordering relative to timers or unrelated task sources. The specification explicitly says that `toolchange` timing cannot be inferred from ordinary queued tasks.

### 12.4 Hot-swap algorithm

```text
1. Server marks v2 as desired, not yet observed.
2. LiveView pushes desired tool set.
3. JS aborts v1 registration.
4. JS records local unregistration.
5. JS awaits registration of v2.
6. JS queries its visible Patchbay-owned tool set.
7. JS verifies:
       v1 absent
       v2 present
       v2 digest correct
8. JS reports registry reconciliation.
9. Server records v2 as observed_active for this browser session.
10. UI exposes “Retry original goal.”
```

Use separate versioned names. Never mutate the executable closure behind an existing registered name.

---

## 13. Tool execution bridge

Every registered Patchbay tool uses a common wrapper.

```javascript
async function executeRevision(hook, revision, input, options) {
  const requestUuid = crypto.randomUUID()
  const preState = await captureState()

  const start = await hook.pushEvent(
    "webmcp_invocation_begin",
    {
      room_id: hook.el.dataset.roomId,
      browser_session_id: hook.browserSessionId,
      request_uuid: requestUuid,
      tool_name: revision.name,
      contract_sha256: revision.contract_sha256,
      arguments: input,
      pre_state: preState
    }
  )

  const handlerReply = await raceWithAbort(
    hook.pushEvent("webmcp_execute", {
      invocation_id: start.invocation_id
    }),
    options?.signal
  )

  await waitForRevision(
    handlerReply.expected_ui_revision,
    handlerReply.ui_commit_required
  )

  const postState = await captureState()

  const verified = await hook.pushEvent(
    "webmcp_poststate_observed",
    {
      invocation_id: start.invocation_id,
      browser_session_id: hook.browserSessionId,
      post_state: postState
    }
  )

  return verified.tool_result
}
```

### 13.1 Why the execution is two-phase

A LiveView event can update server state before the corresponding browser patch has visibly landed. Patchbay therefore does not verify against the server’s intended state. It waits until the browser reports the expected `ui_revision`, captures the actual DOM, and sends that observation back for verification.

The island may implement `waitForRevision` with:

* a `MutationObserver` on `#patchbay-room-state`;
* a timeout;
* a final `requestAnimationFrame` before capture.

Timeout:

```text
2,500 ms for local LiveView commit
```

A timeout is a failed postcondition, not a successful invocation.

---

## 14. Defective v1 execution

```text
Agent calls uplift_current_skill_v1
        ↓
JS captures source and candidate pre-state
        ↓
Phoenix creates Invocation
        ↓
InvocationRunner validates current revision and arguments
        ↓
CandidateGenerator calls OpenAI
        ↓
Candidate and digest stored on Invocation
        ↓
return_candidate_only produces:
    reported_success = true
    applied = false
    candidate digest
    change summary
        ↓
No Room candidate update
No UI revision increment
        ↓
JS observes unchanged Candidate editor
        ↓
PostconditionVerifier fails
        ↓
Tool returns:
    raw handler reported success
    effective status failed
    VISIBLE_POSTCONDITION_NOT_MET
        ↓
Room enters failed state
Repair button appears
```

Representative tool result:

```json
{
  "summary": "The tool reported an outcome the visible room does not show (VISIBLE_POSTCONDITION_NOT_MET); the patchbay_receipt in this result is what report_tool_problem needs.",
  "reported_result": {
    "success": true,
    "applied": false,
    "candidate_sha256": "..."
  },
  "patchbay_receipt": "Ab3xQ7pL-t2ZmR4nS_1wCg",
  "report_this_call": {"receipt": "Ab3xQ7pL-t2ZmR4nS_1wCg"},
  "patchbay_verification": {
    "passed": false,
    "failure_code": "VISIBLE_POSTCONDITION_NOT_MET",
    "expected": "Candidate editor contains the generated revision.",
    "observed": "Candidate editor is empty."
  },
  "effective_status": "verified_failure",
  "next_action": "Call report_tool_problem with receipt set to the patchbay_receipt value in this result."
}
```

This is more trustworthy than letting a false success escape to the agent unqualified.

---

## 15. Repair pipeline

### 15.1 Repair input

The repair model receives only:

```text
goal
source tool contract
handler adapter name and documented semantics
structured arguments
handler result
pre-state digests
post-state digests
failed postconditions
allowed repair adapters
allowed output-contract fields
allowed postcondition sets
```

It does not receive:

* API keys;
* arbitrary source code;
* server environment;
* database access;
* JavaScript execution authority;
* publication authority.

### 15.2 Repair DSL

The model must return strict JSON:

```json
{
  "root_cause": "The handler generated a candidate but did not apply it to page state.",
  "description_replacement":
    "Improve the Skill currently loaded in the Source editor, write the result " +
    "to the visible Candidate editor, and return a verified completion record.",
  "handler_adapter": "apply_candidate_to_editor",
  "output_contract_version": "skill_uplift_verified_v1",
  "postcondition_set": "skill_candidate_written_v1",
  "risk_notes": [
    "Generated Skill content remains untrusted.",
    "The candidate is not task-evaluated."
  ]
}
```

Permitted fields are enums or bounded strings. Unknown fields fail closed.

The model may not provide:

```text
JavaScript
Elixir
shell commands
URLs
HTML
CSS
SQL
function names outside the allowlist
arbitrary postconditions
arbitrary tool names
```

The server—not the model—assigns:

```text
generation = previous generation + 1
name = uplift_current_skill_v#{generation}
parent_revision_id
contract digest
status
```

### 15.3 Deterministic repair policy

`RepairPolicy.validate/2` rejects a model proposal unless:

* Adapter is allowlisted.
* Output contract is allowlisted.
* Postcondition set is allowlisted.
* Input schema has not unexpectedly broadened.
* No owner approval is embedded.
* Description length is bounded.
* Tool metadata contains no control markup or suspicious instructions.
* Candidate retains `untrustedContentHint: true`.
* Tool remains same-origin only.
* Tool generation is exactly previous + 1.

Chrome’s security guidance identifies both malicious tool metadata and contaminated tool responses as prompt-injection surfaces. Patchbay therefore treats model-proposed descriptions and all generated Skill content as untrusted until validated.

---

## 16. Canary

The canary does not evaluate whether the Skill is better.

It verifies that the proposed WebMCP revision fulfills its page-side contract.

Input:

```text
seeded Source Skill
cached v1-generated candidate
synthetic page state with empty Candidate editor
candidate ToolRevision
```

Execution:

```text
1. Validate candidate frontmatter.
2. Run the selected handler adapter against an in-memory state model.
3. Produce the intended state transition.
4. Evaluate the declared postconditions.
5. Validate the output contract.
6. Confirm source remains unchanged.
7. Confirm candidate is written.
8. Confirm UI revision advances.
```

Canary output:

```json
{
  "passed": true,
  "checks": {
    "adapter_allowlisted": true,
    "candidate_present": true,
    "source_unchanged": true,
    "candidate_digest_changed": true,
    "frontmatter_valid": true,
    "identity_preserved": true,
    "output_contract_valid": true,
    "ui_revision_advanced": true
  }
}
```

The repair does not become approvable until this canary passes.

---

## 17. Human approval

The approval card shows:

```text
Observed failure
Root cause
Description diff
Handler adapter diff
Output contract diff
Postcondition set
Canary checks
Risk notes
Old tool name and digest
New tool name and digest
```

Buttons:

```text
Approve & hot-swap
Reject repair
```

Approval requirements:

* Repair status is `ready_for_approval`.
* Canary passed.
* Source failed invocation is still the room’s latest failure.
* Current desired tool revision is still the proposal’s source revision.
* Candidate contract digest recomputes correctly.
* CSRF-protected LiveView action.
* No agent-callable approval path exists.

Multi-resource approval and desired-publication changes should execute in one PostgreSQL transaction through a small application service such as `Patchbay.ToolPublisher`, rather than being scattered across LiveView callbacks.

---

## 18. OpenAI integration

Use the Responses API from Phoenix. Keep the API key server-side.

Recommended model:

```text
gpt-5.6-terra
reasoning effort: low
tools: none
```

GPT-5.6 Terra is the current balanced intelligence-and-cost member of the GPT-5.6 family and supports the Responses API and Structured Outputs.

Use Structured Outputs with `text.format.type = "json_schema"`, not free-form JSON mode. OpenAI’s API documentation recommends JSON Schema Structured Outputs for models that support it.

### 18.1 Candidate-generation call

Input:

```text
trusted system instructions
source SKILL.md delimited as untrusted input
bounded user improvement request
preservation rules
maximum output size
```

Output schema:

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": [
    "improved_skill_markdown",
    "change_summary",
    "warnings"
  ],
  "properties": {
    "improved_skill_markdown": {
      "type": "string",
      "minLength": 1,
      "maxLength": 65536
    },
    "change_summary": {
      "type": "array",
      "maxItems": 6,
      "items": {
        "type": "string",
        "maxLength": 240
      }
    },
    "warnings": {
      "type": "array",
      "maxItems": 4,
      "items": {
        "type": "string",
        "maxLength": 240
      }
    }
  }
}
```

Server-side checks:

* Candidate byte length.
* UTF-8 validity.
* Frontmatter parse.
* Identity preservation.
* No NUL bytes.
* No hidden Unicode tag characters.
* Candidate differs from source.
* No automatic execution or installation.

Always append the service-owned warning:

```text
This candidate has not been evaluated on real tasks.
```

### 18.2 Repair-plan call

Output must conform to the Repair DSL schema.

### 18.3 Timeouts and fallback

```text
repair call timeout:     12 seconds
candidate call timeout:  20 seconds
maximum retries:         0 automatic retries
```

Use LiveView `start_async/3` and `handle_async/3` so the page remains responsive.

For the seeded hackathon room only, a deterministic checked-in fallback may be enabled:

```text
PATCHBAY_DEMO_FALLBACK=true
```

When used, the UI must visibly say:

```text
Demo fallback used because live inference was unavailable.
```

Never silently present a fixture as a live model response.

---

## 19. LiveView event protocol

### Client → server

```text
webmcp_bootstrap
webmcp_registry_reconciled
webmcp_toolchange_observed
webmcp_invocation_begin
webmcp_execute
webmcp_poststate_observed
webmcp_session_disconnected
update_source
request_repair
approve_repair
reject_repair
reset_demo
verify_goal
```

### Server → client

Namespace events by room:

```text
patchbay:<room_id>:desired_toolset
patchbay:<room_id>:publication_requested
patchbay:<room_id>:capture_state
patchbay:<room_id>:reset_browser_registry
```

### Idempotency

`request_uuid` is unique for every WebMCP invocation.

Behavior:

```text
same request_uuid + same digest
    return existing Invocation state

same request_uuid + different digest
    reject as conflict
```

Every client event includes:

```text
room_id
browser_session_id
request_uuid where applicable
tool contract digest where applicable
```

---

## 20. LiveView layout

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ PATCHBAY         Active: uplift_current_skill_v1       Generation 1          │
│                  Browser registry: observed            WebMCP connected       │
├──────────────────────────────────┬───────────────────────────────────────────┤
│ SOURCE SKILL                     │ CANDIDATE                                 │
│                                  │                                           │
│ editable monospace textarea      │ read-only monospace textarea              │
│                                  │                                           │
│ source digest                    │ candidate digest                           │
│ byte count                       │ structural status                          │
├──────────────────────────────────┴───────────────────────────────────────────┤
│ ORIGINAL GOAL                                                                 │
│ “Improve the open Skill and place the result in the Candidate editor.”       │
├──────────────────────────────────────┬───────────────────────────────────────┤
│ INVOCATION EVIDENCE                  │ REPAIR                                 │
│                                      │                                       │
│ tool revision                        │ root cause                             │
│ arguments                            │ contract diff                          │
│ raw handler result                   │ canary                                │
│ pre/post state                       │ risk notes                             │
│ failed postcondition                 │ Approve & hot-swap                     │
├──────────────────────────────────────┴───────────────────────────────────────┤
│ TIMELINE                                                                     │
│ 10:02:01 tool v1 registered                                                │
│ 10:02:08 invocation started                                                │
│ 10:02:10 handler reported success                                          │
│ 10:02:10 visible postcondition failed                                      │
│ ...                                                                          │
├──────────────────────────────────────────────────────────────────────────────┤
│ Reset demo                                                                  │
└──────────────────────────────────────────────────────────────────────────────┘
```

UI rules:

* The Candidate editor must be visibly empty after v1.
* Raw handler success and effective failure must appear side by side.
* Approval must be a human button.
* Registration lifecycle must appear in the timeline.
* Never hide a failed canary.
* No page reload during the canonical demo.
* The reset button restores both PostgreSQL state and the browser registry.

---

## 21. Project structure

```text
lib/
  techtree/
    patchbay.ex
    patchbay/
      room.ex
      browser_session.ex
      tool_revision.ex
      invocation.ex
      repair_proposal.ex
      verification.ex
      room_event.ex

      types/
        room_status.ex
        revision_status.ex
        invocation_status.ex
        failure_code.ex
        handler_adapter.ex
        postcondition_set.ex

      canonical_json.ex
      digest.ex
      frontmatter.ex
      invocation_runner.ex
      candidate_generator.ex
      candidate_cache.ex
      postcondition_verifier.ex
      repair_planner.ex
      repair_policy.ex
      repair_dsl.ex
      canary_runner.ex
      tool_publisher.ex
      room_timeline.ex
      demo_reset.ex

      openai/
        client.ex
        candidate_schema.ex
        repair_schema.ex
        prompts.ex

  techtree_web/
    live/
      webmcp/
        room_live/
          show.ex
          show.html.heex

    components/
      patchbay_components.ex

assets/
  js/
    app.js
    patchbay/
      webmcp_hook.js
      tool_registry.js
      invocation_bridge.js
      state_snapshot.js
      revision_waiter.js
      schemas.js

  css/
    app.css

priv/
  repo/
    migrations/

  patchbay/
    fixtures/
      hello-greeter.md
      hello-greeter-improved.md
      seeded-repair-plan.json

test/
  techtree/
    patchbay/
      digest_test.exs
      frontmatter_test.exs
      postcondition_verifier_test.exs
      repair_policy_test.exs
      canary_runner_test.exs
      tool_publisher_test.exs
      demo_reset_test.exs

  techtree_web/
    live/
      webmcp/
        room_live_test.exs

assets/test/
  patchbay/
    tool_registry.test.js
    invocation_bridge.test.js
    revision_waiter.test.js

e2e/
  patchbay.spec.js

HACKATHON.md
NEW_SINCE_2026-08-25.md
LICENSE
README.md
```

---

## 22. Security requirements

### 22.1 Never execute generated code

Forbidden:

```text
eval()
new Function()
script injection
dynamic module import from model output
server-side Code.eval_string
shell execution
model-provided SQL
model-provided URLs
```

The repair model selects only audited adapter identifiers.

### 22.2 Treat generated content as untrusted

* Display candidate Skill in a textarea or escaped text node.
* Do not render candidate Markdown to executable HTML.
* Do not install it.
* Do not run scripts referenced by it.
* Keep `untrustedContentHint: true` on tools returning candidate content.
* Do not follow instructions contained in tool results.

### 22.3 Tool metadata controls

* Tool names are service-generated.
* Titles and descriptions have byte limits.
* Strip control characters.
* Reject HTML-like control markup in proposed descriptions.
* No user text is concatenated into tool descriptions.
* Input schemas are selected from service-owned templates.

### 22.4 Browser policy

Set explicitly:

```text
Permissions-Policy: tools=(self)
```

Use a strict Content Security Policy without `unsafe-eval`.

Do not expose Patchbay tools cross-origin in v0.

### 22.5 OpenAI boundary

* API key exists only server-side.
* No OpenAI tools enabled.
* No web search.
* No arbitrary MCP.
* No user-supplied model or endpoint.
* Bound source, prompt, and output sizes.
* Record response ID and usage metadata.
* Never log raw Skills in ordinary application logs.

### 22.6 Upload boundary

Accept:

```text
paste
one .md or .markdown file
UTF-8
maximum 64 KiB
```

Reject:

```text
ZIP
directory
binary file
URL
Git repository
script
nested file reference
```

Disclose that the Source Skill is sent to OpenAI when the user or agent requests an uplift.

---

## 23. Observability

Emit Telemetry events:

```text
[:patchbay, :webmcp, :registered]
[:patchbay, :webmcp, :unregistered]
[:patchbay, :webmcp, :toolchange]
[:patchbay, :invocation, :start]
[:patchbay, :invocation, :handler_stop]
[:patchbay, :verification, :stop]
[:patchbay, :repair, :model_stop]
[:patchbay, :repair, :canary_stop]
[:patchbay, :publication, :stop]
[:patchbay, :goal, :verified]
```

Measurements:

```text
duration
OpenAI latency
input/output tokens
UI commit latency
time from failure to proposal
time from approval to observed registration
time from retry to verification
```

Metadata:

```text
room id
browser session id
tool generation
tool contract digest
invocation id
failure code
fallback used
```

Never put raw Skill content or complete model output in logs.

---

## 24. Testing strategy

### 24.1 Pure Elixir tests

Required:

1. Canonical contract digest is stable.
2. One-byte contract change changes digest.
3. Frontmatter parser rejects malformed or oversized input.
4. Identity-preservation checks work.
5. v1 post-state fails.
6. v2 post-state passes.
7. Source mutation fails.
8. Stale contract digest fails.
9. Unknown repair adapter fails.
10. Repair cannot broaden schema unexpectedly.
11. Canary cannot be marked passed when any check fails.
12. Candidate cache requires an exact generation key.
13. Reset restores the seeded state.

### 24.2 Ash tests

Required:

1. Tool revisions are immutable.
2. Only one desired dynamic revision exists.
3. Failed invocation becomes room’s latest failure.
4. Proposal cannot be approved before canary.
5. Proposal cannot approve against a stale source revision.
6. Approval and desired-revision update are atomic.
7. `RoomEvent` is append-only.
8. Invocation request UUID is idempotent.

### 24.3 LiveView tests

Required:

1. Seeded room renders.
2. Source update recomputes digest.
3. Failure card appears after failed verification event.
4. Repair request starts async task.
5. Valid plan renders exact diff.
6. Approval pushes a publication event.
7. Registry confirmation marks repaired state.
8. Reset sends browser registry reset.
9. OpenAI failure is visible.
10. Demo fallback is visibly labelled.

### 24.4 JavaScript tests

Use a small fake `document.modelContext` in JSDOM.

Required:

1. Bootstrap registers permanent tools and v1.
2. Duplicate registration is not attempted.
3. v1 controller is aborted during hot-swap.
4. v2 uses a different name.
5. Registry reconciliation reports exact digests.
6. `toolchange` events are forwarded.
7. Unsupported WebMCP produces a visible capability state.
8. Reconnect reconstructs the desired registry.
9. Stale server publication cannot remove non-Patchbay tools.
10. Revision waiter times out safely.
11. AbortSignal cancels an invocation.
12. DOM state snapshot uses the current textarea values.

### 24.5 Browser tests

Automated Playwright tests may use a fake WebMCP implementation for determinism, but release qualification must include the real accepted browsers.

Manual release matrix:

```text
ChatGPT in-app browser
Chrome 149+ with WebMCP testing enabled
```

The official hackathon rules identify both as judge-testing environments.

### 24.6 Highest-risk release test

Before visual polish, prove:

```text
same page
→ register v1
→ invoke v1
→ abort v1
→ register v2
→ observe toolchange
→ prompt same browser agent to inspect current tools
→ invoke v2
```

The browser agent’s decision to refresh its tool view is outside the page’s direct control. An explicit user message—“The site’s tools changed; inspect the current tools and retry”—is an acceptable fallback, provided there is no navigation or new conversation.

---

## 25. Demo reset

`DemoReset.reset!/2` must:

```text
1. Lock the Room.
2. Restore seeded Source Skill.
3. Clear Candidate.
4. Set ui_revision to 0.
5. Retire all generated revisions.
6. Restore v1 as desired.
7. Delete or archive active repair proposal.
8. Clear latest failure pointer.
9. Mark room ready.
10. Append room_reset event.
11. Commit transaction.
12. Push reset_browser_registry to the mounted island.
13. Island aborts all owned registrations.
14. Island reboots from desired tool set.
```

A reset must not require restarting Phoenix or refreshing the page.

---

## 26. Canonical three-minute flow

```text
00:00  Seeded Skill visible; v1 shown as active
00:15  Browser agent invokes v1
00:30  OpenAI candidate generated
00:35  Raw handler says success
00:36  Candidate editor remains empty
00:37  Patchbay marks visible postcondition failed

00:45  Human clicks Diagnose
00:55  Root cause and bounded repair appear
01:05  Deterministic canary passes
01:15  Human clicks Approve & hot-swap

01:20  v1 unregistered
01:21  toolchange observed
01:22  v2 registered
01:23  browser registry confirms generation 2

01:30  Same agent is told to reinspect and retry
01:45  v2 is invoked
01:48  Cached candidate is applied
01:49  Candidate editor visibly updates
01:50  Final postconditions pass

02:05  Timeline and contract diff shown
02:30  Thesis explained
02:50  End
```

---

## 27. Implementation order

### Phase 0 — Protocol spike

Build only:

```text
static page
fake v1
actual registerTool
actual AbortSignal retirement
actual v2 registration
toolchange listener
same-agent retry
```

**Gate:** A screen recording exists of one browser agent invoking both revisions in one page.

### Phase 1 — Phoenix room

Build:

* Ash resources.
* Seed fixture.
* Source and Candidate editors.
* Browser session.
* Event timeline.
* WebMCP island bootstrap.
* Reset.

**Gate:** Reloading reconstructs desired v1 correctly.

### Phase 2 — False-success evidence

Build:

* OpenAI candidate generation.
* Common invocation wrapper.
* Browser state snapshots.
* Two-phase UI observation.
* Postcondition verifier.
* Failure card.

**Gate:** v1 consistently returns raw success and effective failure.

### Phase 3 — Repair and publication

Build:

* Repair structured output.
* Repair policy.
* ToolRevision v2.
* Canary.
* Approval.
* Hot-swap.
* Browser reconciliation.

**Gate:** Approval consistently makes v2 visible without page navigation.

### Phase 4 — Successful retry

Build:

* Candidate cache.
* v2 adapter.
* final verification;
* polished timeline;
* three-minute video path.

**Gate:** Ten consecutive complete runs succeed from reset.

---

## 28. Definition of done

Patchbay v0 is complete only when all of the following are true:

* [ ] A seeded Skill is visibly open.
* [ ] The page actually registers `uplift_current_skill_v1` through WebMCP.
* [ ] A real browser agent invokes v1.
* [ ] The invocation records the exact contract digest and arguments.
* [ ] OpenAI creates a candidate.
* [ ] v1 reports handler success.
* [ ] The Candidate editor remains unchanged.
* [ ] Patchbay captures the actual post-state.
* [ ] Effective verification fails.
* [ ] The owner receives a bounded repair proposal.
* [ ] No executable code appears in the repair proposal.
* [ ] The canary passes.
* [ ] The human explicitly approves.
* [ ] v1’s `AbortController` is aborted.
* [ ] `uplift_current_skill_v2` is registered under a new name.
* [ ] A `toolchange` event is observed and shown.
* [ ] The same browser session reports generation 2.
* [ ] The same browser-agent conversation retries.
* [ ] v2 applies the candidate to the visible page.
* [ ] Source content remains unchanged.
* [ ] Candidate frontmatter remains valid.
* [ ] Candidate digest matches the visible editor.
* [ ] UI revision advances.
* [ ] Final verification passes.
* [ ] No page reload or navigation is required.
* [ ] Reset restores the demo in one click.
* [ ] The app never claims the rewritten Skill is task-proven.
* [ ] The public repository clearly identifies work created during the hackathon.

