defmodule Patchbay.MigrationSchemaTest do
  @moduledoc """
  Production keeps Patchbay's tables in the product's own schema; a
  developer's database and the tests keep them in `public`. The migrator moves
  `create`, `alter` and `constraint` to the right schema by itself, but a
  statement a migration writes out by hand runs exactly as written. One that
  names no schema works here and stops the release there, so every such
  statement has the schema put into it, and its migration takes that schema
  from `prefix()`. The database helpers and extensions every site shares live
  in `public`, so a statement for one of them names `public` itself
  (`public.ash_required`, `WITH SCHEMA public`). A setting names nothing to
  put a schema in: one for the migration's own transaction (`SET LOCAL`), or,
  for a migration that runs outside a transaction, one set for its connection
  and put back at the end (`SET`, `RESET`).
  """

  use ExUnit.Case, async: true

  # The last migration of the imported history, the line `Patchbay.Release`
  # draws too. Nothing up to it ever runs in the product's schema.
  @imported_through 20_260_904_074_137

  test "every statement a migration writes by hand takes the schema from prefix()" do
    names_no_schema =
      for path <-
            Patchbay.Repo
            |> Ecto.Migrator.migrations_path()
            |> Path.join("*.exs")
            |> Path.wildcard(),
          version(path) > @imported_through,
          source = File.read!(path),
          {line, statement} <- hand_written(source),
          not (String.contains?(source, "prefix()") and value_put_in?(statement)),
          not names_public?(statement),
          not setting?(statement),
          do: "#{Path.basename(path)}:#{line}"

    assert names_no_schema == []
  end

  # Each thing handed to `execute`, with the line it is on.
  defp hand_written(source) do
    {_ast, statements} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:execute, meta, [_ | _] = statements} = call, found ->
          {call, Enum.map(statements, &{meta[:line], &1}) ++ found}

        other, found ->
          {other, found}
      end)

    statements
  end

  # Text with a value put into it, which is how a statement carries the schema.
  # Text written out whole names none.
  defp value_put_in?({:<<>>, _meta, _parts}), do: true
  defp value_put_in?(_statement), do: false

  defp names_public?(statement) when is_binary(statement),
    do: statement =~ ~r/\bpublic\.|\bSCHEMA public\b/

  defp names_public?(_statement), do: false

  defp setting?(statement) when is_binary(statement),
    do: statement =~ ~r/\A(SET (LOCAL )?\w+ = '[^']*'|RESET \w+)\z/

  defp setting?(_statement), do: false

  defp version(path) do
    {version, _name} = path |> Path.basename() |> Integer.parse()
    version
  end
end
