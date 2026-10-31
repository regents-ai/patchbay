defmodule Patchbay.Repo.Migrations.OAuthHashedTokens do
  @moduledoc """
  ChatGPT's connection tokens at the provider's current version:
  `RegentOAuth.Migration.V2` keeps only the SHA-256 hash of each access and
  refresh token, so an app connected before it keeps the tokens it holds and no
  plain token stays in the table.

  Each code and token gets the site's issuer and resource written on it as it is
  issued, so V2 drops the address defaults `20261029120000_oauth_on_open_address`
  set; the rows already there keep the values they have.

  Up only: a hash does not give back its token. V2 rewrites every access token
  row in place, so on the shared production database it runs only with the
  founder's go.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    RegentOAuth.Migration.V2.up()
  end

  def down do
    raise "A hashed token cannot be turned back into its token; restore a reviewed recovery copy instead."
  end
end
