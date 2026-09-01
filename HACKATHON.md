# Patchbay hackathon brief

## The problem

An agent can receive a successful-looking handler response while the user sees
no useful change. Treating that response as truth makes retries, repairs and
tool updates unsafe.

## The demo

Patchbay keeps one goal, one LiveView room and one browser session in view. The
seeded `uplift_current_skill_v1` contract intentionally returns apparent
success without writing the Candidate editor. The page records both facts:
the raw handler result is `success`, while server-side visible verification
produces `CANDIDATE_EMPTY` and a durable failed invocation.

The repair path is deliberately bounded:

1. A repair proposal is derived from the failed invocation and checked-in
   policy.
2. The contract diff and deterministic canary are shown to the owner.
3. A human clicks **Approve & hot-swap**. Browser tools have no approval path.
4. The server publishes the distinct `uplift_current_skill_v2` revision.
5. The WebMCP hook retires the old registration, registers v2, and reports the
   observed generation and exact contract digest.
6. The same goal is retried without navigation. v2 writes the Candidate
   editor, advances the UI revision, and the server records a verified result.

The reset action restores the checked-in source, clears the visible candidate,
disconnects browser-session evidence and returns the desired registry to G1.

## Why WebMCP matters here

The browser hook exposes structured tools for room state, verification and the
current revision. It uses WebMCP as progressive enhancement: when the browser
does not support the experimental API, the page remains inspectable and its
human controls still work. The server does not trust tool names, browser
claims, or model text merely because they arrived from a browser.

## Running the proof

Use the deterministic local walkthrough in [README.md](README.md), then run:

```sh
bash script/deterministic_e2e.sh
```

This repeats the focused LiveView lifecycle and the fake-WebMCP JavaScript
lifecycle ten times across isolated local test partitions. It is deterministic
integration evidence; the real-browser walkthrough remains a separate check.
The proof uses no live model, external browser service, or public endpoint. The
full command/evidence matrix is in the README.

## Boundaries

This is a hackathon prototype. Authentication, production deployment,
multi-tenant policy, model-quality evaluation, arbitrary code execution,
automatic approval and real-money or production-data actions are outside the
demo. The fallback fixture is not a substitute for live evaluation.
