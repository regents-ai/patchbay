defmodule Patchbay.Repo.Migrations.AddOAuthProvider do
  use Ecto.Migration

  def up do
    RegentOAuth.Migration.up(
      issuer: "https://patchbay.help",
      resource: "https://patchbay.help/chatgpt/mcp"
    )
  end
end
