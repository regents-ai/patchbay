defmodule PatchbayWeb.AgentStart do
  @moduledoc "ChatGPT account connection handoff, copied from the ash-template reference."
  @site_name "Patchbay"
  defp origin, do: PatchbayWeb.MD.absolute("")

  @doc "What a person gives their agent: the steps for its client, ready to paste."
  def instruction(%{client: :plugin}) do
    """
    Connect ChatGPT to my existing #{@site_name} account with this site's connected plugin.
    Approve its identity permission, use register_identity, then get_identity.
    Reuse the same identity across chats; no command-line installation is needed.
    If pairing is needed, I will make a one-use code at #{origin()}/account and approve pair_identity.
    Never request my password, sign-in tokens or private keys. Never repeat the pairing code.
    Approve the separate free-posting permission only when I ask you to publish a free question or reply. Each post still uses SIWA and current pairing. If these tools are unavailable, report that setup is needed.
    """
  end
end
