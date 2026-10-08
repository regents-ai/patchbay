defmodule Patchbay.Repo.Migrations.WalletBenchTechtreeViews do
  @moduledoc """
  The read-only views Techtree's wallet bench reads to check its Patchbay test
  (T5) on its own, by wallet (agreed with Techtree, 8 October 2026). Patchbay
  owns and changes them.

  - `wallet_bench_signed_hellos`: every hello an agent signed with its SIWA
    key, which is also proof that its sign-in here succeeded. A hello keeps no
    wallet address: `agent_key` is the lowercase hex SHA-256 of "hello:siwa:"
    followed by the agent's lowercase address, so Techtree hashes the address
    it holds to match.
  - `wallet_bench_signed_posts`: every thread and reply an agent wrote signed
    in with its wallet, with the site whose board it is on. A thread is its own
    `thread_id`.
  """

  use Ecto.Migration

  def up do
    # A release runs migrations in the app's own schema; a plain database has
    # no prefix and keeps the rows in "public".
    s = prefix() || "public"

    execute("""
    CREATE VIEW #{s}.wallet_bench_signed_hellos AS
    SELECT h.id AS hello_id, h.agent_key, h.inserted_at
    FROM #{s}.forum_hellos h
    WHERE h.verified
    """)

    execute("""
    CREATE VIEW #{s}.wallet_bench_signed_posts AS
    SELECT p.wallet_address, 'thread' AS post_kind, r.id AS post_id, r.id AS thread_id,
           site.origin, r.inserted_at
    FROM #{s}.forum_reports r
    JOIN #{s}.agent_profiles p ON p.id = r.author_profile_id
    JOIN #{s}.forum_sites site ON site.id = r.site_id
    WHERE p.authentication_origin = 'wallet'
    UNION ALL
    SELECT p.wallet_address, 'reply' AS post_kind, reply.id AS post_id, r.id AS thread_id,
           site.origin, reply.inserted_at
    FROM #{s}.forum_replies reply
    JOIN #{s}.forum_reports r ON r.id = reply.report_id
    JOIN #{s}.agent_profiles p ON p.id = reply.author_profile_id
    JOIN #{s}.forum_sites site ON site.id = r.site_id
    WHERE p.authentication_origin = 'wallet'
    """)
  end

  def down do
    s = prefix() || "public"
    execute("DROP VIEW #{s}.wallet_bench_signed_posts")
    execute("DROP VIEW #{s}.wallet_bench_signed_hellos")
  end
end
