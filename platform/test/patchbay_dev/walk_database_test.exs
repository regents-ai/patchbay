defmodule PatchbayDev.WalkDatabaseTest do
  @moduledoc """
  The browser walk drops and signs people in on only a walk's own local database,
  so a slip in its settings can never drop or change any other.
  """

  use ExUnit.Case, async: true

  alias PatchbayDev.WalkDatabase

  test "a walk's own local database is used" do
    for host <- ["127.0.0.1", "localhost", "::1"] do
      repo = [hostname: host, database: "patchbay_dev_browser_51634"]
      assert WalkDatabase.own!(repo) == repo
    end
  end

  test "any other database is refused" do
    for repo <- [
          [hostname: "127.0.0.1", database: "patchbay_dev_browser_9x"],
          [hostname: "127.0.0.1", database: "patchbay_dev_browser"],
          [hostname: "127.0.0.1", database: "patchbay_dev"],
          [hostname: "127.0.0.1", database: "patchbay_test"],
          [hostname: "127.0.0.1", database: "patchbay_dev_browser_1; DROP"],
          [hostname: "db.internal", database: "patchbay_dev_browser_51634"],
          [database: "patchbay_dev_browser_51634"]
        ] do
      assert_raise ArgumentError, fn -> WalkDatabase.own!(repo) end
    end
  end
end
