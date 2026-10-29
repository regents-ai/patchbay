defmodule Patchbay.Repo.Migrations.OAuthOnOpenAddress do
  use Ecto.Migration

  # ChatGPT connects at open.patchbay.help now. Tokens issued from here on
  # carry its issuer and resource; those issued for patchbay.help are revoked,
  # so each connection is made again at the new address.
  def up do
    # A release runs migrations in the app's own schema; a plain database has
    # no prefix and keeps the rows in "public".
    schema = prefix() || "public"

    alter table(:oauth_tokens) do
      modify :oauth_issuer, :text, null: false, default: "https://open.patchbay.help"

      modify :mcp_resource, :text,
        null: false,
        default: "https://open.patchbay.help/chatgpt/mcp"
    end

    execute """
    UPDATE #{schema}.oauth_tokens
    SET revoked_at = COALESCE(revoked_at, now()),
        refresh_token_revoked_at = COALESCE(refresh_token_revoked_at, now())
    WHERE oauth_issuer = 'https://patchbay.help'
    """
  end

  # The revoked tokens stay revoked.
  def down do
    alter table(:oauth_tokens) do
      modify :oauth_issuer, :text, null: false, default: "https://patchbay.help"
      modify :mcp_resource, :text, null: false, default: "https://patchbay.help/chatgpt/mcp"
    end
  end
end
