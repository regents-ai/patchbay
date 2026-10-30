defmodule Patchbay.Repo.Migrations.OAuthConnectorTokens do
  @moduledoc """
  The ChatGPT plugin's sign-in tables at the provider's current version.
  `RegentOAuth.Migration` made them (`20261014170000_add_oauth_provider`);
  `RegentOAuth.Migration.V2` now keeps only the SHA-256 hash of each access and
  refresh token, so an app connected before it keeps the tokens it holds and no
  plain token stays in the table.

  Neither needs the site's address: each code and token gets this site's issuer
  and resource written on it as it is issued, and one whose values differ from
  the running site's is refused. V2 drops the old address defaults; the rows
  already there keep the values they have.

  Up only: a hash does not give back its token. V2 rewrites every existing
  access token row in place, so on the shared production database it runs only
  with the founder's go.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    RegentOAuth.Migration.V2.up()
  end
end
