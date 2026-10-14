defmodule Patchbay.SharedAccountTable do
  @moduledoc """
  The shared Regent account table, which Regents owns and migrates in
  production, in the shape the Regent template's local fixture gives it. A
  test database gets it from these statements.
  """

  def statements do
    [
      "CREATE SCHEMA IF NOT EXISTS regent_names",
      """
      CREATE TABLE IF NOT EXISTS regent_names.platform_human_users (
        id bigserial PRIMARY KEY,
        privy_user_id varchar(255) NOT NULL UNIQUE,
        wallet_address varchar(255),
        wallet_addresses varchar(255)[] NOT NULL DEFAULT '{}',
        world_human_id varchar(255) UNIQUE,
        world_verified_at timestamp(0) without time zone,
        display_name varchar(80),
        avatar jsonb,
        created_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL
      )
      """
    ]
  end
end
