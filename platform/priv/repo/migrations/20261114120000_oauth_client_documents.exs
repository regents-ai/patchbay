defmodule Patchbay.Repo.Migrations.OAuthClientDocuments do
  @moduledoc """
  Published identities for connected apps, such as ChatGPT's: an app that names
  itself by an HTTPS address is recorded as an ordinary client, and
  `RegentOAuth.Migration.V3` adds the one table that remembers which address
  each such client came from and when to read it again.

  Additive only: one new, empty table and its index, in the schema the site's
  other connected-app tables live in. Nothing existing changes.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    RegentOAuth.Migration.V3.up()
  end
end
