defmodule Patchbay.Repo.Migrations.OAuthConnectorScopes do
  @moduledoc """
  patchbay.help's own sign-in for connected apps (`Patchbay.OAuth`, `:main`)
  offers asking and replying (`patchbay.posts.write`) beside the identity
  permission. Apps are one table for both addresses, so every app already
  recorded may be offered every permission either address has
  (`RegentOAuth.Migration.ClientScopes`); each address still grants only its
  own, and only with the person's consent.

  Additive only: it inserts the scope rows and app links that are missing and
  changes nothing already there.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    RegentOAuth.Migration.ClientScopes.up([
      "patchbay.events.read",
      "regent.identity.manage",
      "patchbay.posts.write"
    ])
  end
end
