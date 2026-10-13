defmodule Patchbay.MigrationSchemaTest do
  @moduledoc """
  Production keeps Patchbay's tables in the product's own schema; a
  developer's database and the tests keep them in `public`. The migrator moves
  `create`, `alter` and `constraint` to the right schema by itself, but a
  statement a migration writes out by hand runs exactly as written. One that
  names no schema works here and stops the release there, so every such
  migration takes the schema from `prefix()`.
  """

  use ExUnit.Case, async: true

  # The last migration of the imported history, the line `Patchbay.Release`
  # draws too. Nothing up to it ever runs in the product's schema.
  @imported_through 20_260_904_074_137

  test "a migration that writes a statement by hand takes the schema from prefix()" do
    names_no_schema =
      for path <-
            Patchbay.Repo
            |> Ecto.Migrator.migrations_path()
            |> Path.join("*.exs")
            |> Path.wildcard(),
          version(path) > @imported_through,
          source = File.read!(path),
          source =~ ~r/\bexecute\b/,
          not String.contains?(source, "prefix()"),
          do: Path.basename(path)

    assert names_no_schema == []
  end

  defp version(path) do
    {version, _name} = path |> Path.basename() |> Integer.parse()
    version
  end
end
