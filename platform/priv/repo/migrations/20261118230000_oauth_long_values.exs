defmodule Patchbay.Repo.Migrations.OAuthLongValues do
  @moduledoc """
  Connected apps: every column an accepted request can fill past 255
  characters loses that limit (`RegentOAuth.Migration.V4`). The code's state
  and callback were widened by the migration before this one; this adds an
  app's name, the address of its keys and its list of callbacks.

  Widening only: no stored row changes, nothing is rewritten, dropped, renamed
  or narrowed.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    RegentOAuth.Migration.V4.up()
  end

  def down, do: :ok
end
