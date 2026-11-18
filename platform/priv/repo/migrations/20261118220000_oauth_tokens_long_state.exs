defmodule Patchbay.Repo.Migrations.OAuthTokensLongState do
  use Ecto.Migration

  # An app's `state` and callback address are kept with its authorization
  # code. Boruta made both varchar(255); ChatGPT's portal sends a longer
  # state, which a request may carry up to the consent page's own bound, and a
  # callback address may be 2048 bytes. Widening to text rewrites no row.
  def up do
    alter table(:oauth_tokens) do
      modify :state, :text
      modify :redirect_uri, :text
    end
  end

  # The wider columns stay: a long value already kept would not fit back.
  def down, do: :ok
end
