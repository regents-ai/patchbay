import {signedTools, type SignedOperation} from "../../vendor/regent_agent_access/signed_tools.ts";
import manifest from "../../../priv/tool_manifest.json" with {type: "json"};

// Only the signed tools are operations; each is sent with its operation's own inputs.
const OPERATIONS = manifest.tools.flatMap(entry =>
  "operation_input_schema" in entry ? [{...entry, input_schema: entry.operation_input_schema}] : [],
) as unknown as SignedOperation[];

/**
 * Every operation prepare_agent_request may prepare: each signed tool that is
 * available. Its list is read from them, as Patchbay.Forum.Capabilities reads
 * it for /forum/capabilities, so it can never leave one out.
 */
export const PREPARABLE_OPERATIONS = OPERATIONS
  .filter(operation => operation.authentication === "siwa_per_request" && operation.availability === "available")
  .map(operation => operation.name);

export function signedTransport() {
  return signedTools({origin: window.location.origin,
    trustedOrigins: [document.querySelector<HTMLMetaElement>('meta[name="agent-request-origin"]')?.content ?? ""],
    audience: manifest.audience, proofHeaders: manifest.proof_headers, operations: OPERATIONS,
  });
}
