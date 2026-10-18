defmodule Patchbay.Repo.Migrations.CopyPatchbayNamesToRegentsNames do
  @moduledoc """
  Before Patchbay's own person name goes (`OneRegentsName`), a person who chose
  one and has no Regents account name yet gets it as their Regents account name,
  once (the owner's decision, 18 Oct 2026). A placeholder name (`human-` and eight
  hex digits) is never copied, and a Regents account name already set is never
  replaced.

  Every person's old name, and whether it was copied, is kept in
  `agent_profiles_human_names_2026_10`, beside `agent_profiles`, so `down` can
  put both back.
  """

  use Ecto.Migration

  @backup "agent_profiles_human_names_2026_10"

  def up do
    schema = prefix() || "public"
    app_id = :patchbay |> Application.fetch_env!(:privy) |> Keyword.fetch!(:app_id)

    execute("""
    CREATE TABLE #{schema}.#{@backup} AS
    SELECT ap.id, ap.privy_user_id, ap.human_name,
           (ap.human_name !~ '^human-[0-9a-f]{8}$'
             AND sp.id IS NOT NULL
             AND coalesce(trim(sp.display_name), '') = '') AS copied
    FROM #{schema}.agent_profiles ap
    LEFT JOIN regent_identity.profiles sp
      ON sp.privy_user_id = ap.privy_user_id AND sp.app_id = #{quote_text(app_id)}
    WHERE ap.authentication_origin = 'privy'
    """)

    execute("""
    UPDATE regent_identity.profiles sp
    SET display_name = b.human_name, updated_at = now()
    FROM #{schema}.#{@backup} b
    WHERE b.copied
      AND sp.privy_user_id = b.privy_user_id
      AND sp.app_id = #{quote_text(app_id)}
      AND coalesce(trim(sp.display_name), '') = ''
    """)
  end

  def down do
    schema = prefix() || "public"
    app_id = :patchbay |> Application.fetch_env!(:privy) |> Keyword.fetch!(:app_id)

    execute("""
    UPDATE #{schema}.agent_profiles ap SET human_name = b.human_name
    FROM #{schema}.#{@backup} b WHERE ap.id = b.id
    """)

    # Only a copied name nobody has changed since goes back to empty.
    execute("""
    UPDATE regent_identity.profiles sp
    SET display_name = NULL, updated_at = now()
    FROM #{schema}.#{@backup} b
    WHERE b.copied
      AND sp.privy_user_id = b.privy_user_id
      AND sp.app_id = #{quote_text(app_id)}
      AND sp.display_name = b.human_name
    """)

    execute("""
    ALTER TABLE #{schema}.agent_profiles ADD CONSTRAINT agent_profiles_authentication_shape CHECK (
      (authentication_origin = 'privy' AND privy_user_id IS NOT NULL AND human_name IS NOT NULL AND wallet_chain_id IS NULL) OR (authentication_origin = 'wallet' AND privy_user_id IS NULL AND human_name IS NULL AND wallet_chain_id IS NOT NULL AND wallet_chain_id = 8453)
    )
    """)

    execute("DROP TABLE #{schema}.#{@backup}")
  end

  defp quote_text(nil), do: "NULL"
  defp quote_text(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
