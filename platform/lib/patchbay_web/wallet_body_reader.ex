defmodule PatchbayWeb.WalletBodyReader do
  @moduledoc "Signed agent routes keep their exact bytes through the siwa library, each with its own size limit; other routes use the shared profile reader."

  def read_body(%{path_info: path} = conn, opts)
      when path in [["hello"], ["api", "agent", "hello"]],
      do: Siwa.AgentAuthPlug.read_body(conn, opts, 16_384)

  def read_body(%{path_info: ["api", "agent" | _]} = conn, opts),
    do: Siwa.AgentAuthPlug.read_body(conn, opts, 100_000)

  # A shared agent pairing request (`regent_agents`), signed over its exact bytes.
  def read_body(%{path_info: ["api", "agents", "v1" | _]} = conn, opts),
    do: Siwa.AgentAuthPlug.read_body(conn, opts, 16_384)

  def read_body(%{path_info: ["forum" | _]} = conn, opts),
    do: Siwa.AgentAuthPlug.read_body(conn, opts, 100_000)

  def read_body(%{path_info: ["known-fixes" | _]} = conn, opts),
    do: Siwa.AgentAuthPlug.read_body(conn, opts, 100_000)

  def read_body(%{path_info: ["tools" | _]} = conn, opts),
    do: Siwa.AgentAuthPlug.read_body(conn, opts, 100_000)

  def read_body(%{path_info: path} = conn, opts) when path in [["mcp"], ["chatgpt", "mcp"]],
    do: Siwa.AgentAuthPlug.read_body(conn, opts, 100_000)

  def read_body(conn, opts), do: RegentIdentity.BodyReader.read_body(conn, opts)
end
