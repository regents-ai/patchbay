import {signedTools, type SignedOperation} from "../../vendor/regent_agent_access/signed_tools";
import manifest from "../../../priv/tool_manifest.json" with {type: "json"};

export function signedTransport() {
  return signedTools({origin: window.location.origin,
    trustedOrigins: [document.querySelector<HTMLMetaElement>('meta[name="agent-request-origin"]')?.content ?? ""],
    audience: manifest.audience, proofHeaders: manifest.proof_headers,
    operations: manifest.tools.map(entry => ({...entry,
      input_schema: "operation_input_schema" in entry ? entry.operation_input_schema : entry.input_schema,
    })) as unknown as SignedOperation[],
  });
}
