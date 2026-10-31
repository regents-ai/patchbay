import {signedTools, type SignedOperation} from "../../vendor/regent_agent_access/signed_tools.ts";
import manifest from "../../../priv/tool_manifest.json" with {type: "json"};

// Only the signed tools are operations.
const OPERATIONS = manifest.tools.filter(entry => entry.authentication === "siwa_per_request") as unknown as SignedOperation[];

export function signedTransport() {
  return signedTools({origin: window.location.origin,
    trustedOrigins: [document.querySelector<HTMLMetaElement>('meta[name="agent-request-origin"]')?.content ?? ""],
    audience: manifest.audience, proofHeaders: manifest.proof_headers, operations: OPERATIONS,
    // Patchbay labels no calls of its own yet.
    requestHeaders: () => ({}),
  });
}
