defmodule Patchbay.Repo.Migrations.AddOAuthProvider do
  use Ecto.Migration

  def up do
    RegentOAuth.Migration.up()
  end
end
