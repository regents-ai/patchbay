# Patchbay WebMCP verification

Verified on 2026-09-01 against the local Patchbay room at
`/webmcp/rooms/skill-uplift`.

## Coverage

- `get_patchbay_room_state` reads a bounded snapshot of the current page.
- `verify_skill_uplift_goal` derives its answer from trusted page metadata and
  treats user-authored Skill content as untrusted.
- `uplift_current_skill_v1` intentionally reports handler success without
  changing the Candidate editor, producing `CANDIDATE_EMPTY`.
- Owner approval retires v1 and registers the distinct
  `uplift_current_skill_v2` contract in the same document.
- v2 writes the Candidate editor, advances the UI revision, and returns a
  server-verified success. The verifier then reports `passed`.

## Safety and lifecycle checks

- The LiveView accepts registry evidence only for its own permanent tools and
  exact current revision name, generation, and SHA-256 contract digest.
- A stale or forged revision cannot begin an invocation.
- Hook-owned tools are removed on disconnect; foreign tools are never retired.
- Duplicate registration, dropped acknowledgements, reconnect during an
  in-flight bootstrap, registration rejection, invocation abort, and revision
  timeout are covered by tests.
- A `toolchange` observation is reported only after the registry is stable.

## Evidence

- 59 Elixir tests passed on a freshly migrated test database.
- 12 Node WebMCP lifecycle tests passed.
- Strict compilation, formatting, Ash code-generation checks, asset build, and
  diff validation passed.
- A live browser completed the canonical failure, repair, approval, hot-swap,
  retry, and verification loop without navigation.

The demo fallback is intentionally opt-in with
`PATCHBAY_DEMO_FALLBACK=true` when live model inference is unavailable. The UI
labels fallback-generated content and states that it has not been evaluated on
real tasks.
