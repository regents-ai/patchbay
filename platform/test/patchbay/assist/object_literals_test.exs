defmodule Patchbay.Assist.ObjectLiteralsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Patchbay.Assist.ObjectLiterals

  # Objects are generated with what reading them must give back, and written
  # as a script writes them: every key in any quoting, text in any quoting
  # and escape or joined from pieces, values that are code, methods, objects
  # and lists of objects inside objects, and comments between it all.

  property "every object reads back with exactly its own keys, in the order it closes" do
    check all(
            {found, js} <- object(2),
            prefix <- member_of(["navigator.modelContext.registerTool(", "export default ("])
          ) do
      assert ObjectLiterals.read(prefix <> js <> ");") == found
    end
  end

  test "text that cannot be known without running the script is code" do
    assert ObjectLiterals.read(
             ~S|({a: `On ${host}`, b: "x" + y, c: y + "x", d: "x" ? 1 : 2, e: f("x")})|
           ) ==
             [%{"a" => :code, "b" => :code, "c" => :code, "d" => :code, "e" => :code}]
  end

  test "braces in strings, comments and regular expressions are not the script's own" do
    js = ~S"""
    const re = /[{]"/g, half = a / 2 / b;
    // { "name": "commented" }
    ({name: "kept" /* } */, note: '{"name": "quoted"}', re: /}/})
    """

    assert ObjectLiterals.read(js) == [
             %{
               "name" => {:text, "kept"},
               "note" => {:text, ~S|{"name": "quoted"}|},
               "re" => :code
             }
           ]
  end

  test "a lone half of a pair is kept as written, and an object never closed is not listed" do
    assert ObjectLiterals.read(~S|({a: "\uD83D!"}) ({b: "open"|) == [
             %{"a" => {:text, ~S|\uD83D!|}}
           ]
  end

  ## Generators

  defp object(depth) do
    gen all(
          entries <-
            uniq_list_of(entry(depth), uniq_fun: &elem(&1, 0), min_length: 1, max_length: 6),
          gaps <- list_of(gap(), length: length(entries) + 1),
          trailing <- member_of(["", ","])
        ) do
      js =
        entries
        |> Enum.zip(gaps)
        |> Enum.map_join(",", fn {{_key, js, _value, _inner}, gap} -> gap <> js end)

      own = Map.new(entries, fn {key, _js, value, _inner} -> {key, value} end)
      inner = Enum.flat_map(entries, fn {_key, _js, _value, inner} -> inner end)

      {inner ++ [own], "{" <> js <> trailing <> List.last(gaps) <> "}"}
    end
  end

  # One entry: its key, how it is written, what it reads back as, and the
  # objects written inside it.
  defp entry(depth) do
    gen all(
          key <- key(),
          {written_key, kinds} <- written_key(key),
          kind <- member_of(kinds),
          gap <- gap(),
          {js, value, inner} <- value(kind, written_key, key, gap, depth)
        ) do
      {key, js, value, inner}
    end
  end

  defp key do
    one_of([
      member_of(~w(name description inputSchema input_schema execute type properties)),
      member_of(~w(title default in get async)),
      string(:alphanumeric, max_length: 8),
      string(:printable, max_length: 8)
    ])
  end

  # A key that is a name may be written bare, and then may stand alone or
  # name a method; any key may be quoted.
  defp written_key(key) do
    kinds = [:text, :code, :method] ++ if(bare?(key), do: [:shorthand], else: [])

    bare = if bare?(key), do: [constant(key)], else: []

    gen all(written <- one_of(bare ++ [quoted(key, :double), quoted(key, :single)])) do
      {written, if(written == key, do: kinds, else: kinds -- [:shorthand])}
    end
  end

  defp bare?(key), do: key =~ ~r/\A[A-Za-z_$][A-Za-z0-9_$]*\z/

  defp value(:text, written_key, _key, gap, _depth) do
    gen all(text <- text(), js <- written_text(text)) do
      {written_key <> gap <> ":" <> gap <> js, {:text, text}, []}
    end
  end

  defp value(:code, written_key, _key, gap, depth) do
    code =
      member_of([
        "42",
        "3.5e2",
        "x",
        ~S|fn(1, "a)")|,
        "a / b / c",
        ~S|/re[/]x\/y/gi|,
        "async (e) => e",
        ~S|[1, "]", 2]|,
        "`t ${v} u`",
        "x ? 1 : 2",
        ~S|"a" + b|,
        ~S|b + "a"|,
        "-1",
        "typeof x",
        "new Map()"
      ])

    nested =
      if depth > 0 do
        [
          gen(all({inner, js} <- object(depth - 1), do: {js, inner})),
          gen all(objects <- list_of(object(depth - 1), min_length: 1, max_length: 3)) do
            {"[" <> Enum.map_join(objects, ", ", &elem(&1, 1)) <> "]",
             Enum.flat_map(objects, &elem(&1, 0))}
          end
        ]
      else
        []
      end

    gen all({js, inner} <- one_of([gen(all(js <- code, do: {js, []})) | nested])) do
      {written_key <> gap <> ":" <> gap <> js, :code, inner}
    end
  end

  defp value(:method, written_key, _key, gap, _depth) do
    gen all(modifier <- member_of(["", "async ", "get ", "*"])) do
      {modifier <> written_key <> gap <> "(a, b)" <> gap <> "{ return a / 2 }", :code, []}
    end
  end

  defp value(:shorthand, key, _key, _gap, _depth), do: constant({key, :code, []})

  defp gap, do: member_of(["", " ", "\n  ", " /* } { \" ' ` */ ", " // } ' \"\n", "\t"])

  defp text do
    special = [
      "\"",
      "'",
      "`",
      "\\",
      "\n",
      "\r",
      "${",
      "}",
      "{",
      "/*",
      "//",
      " ",
      "é",
      "😀",
      "\t",
      "$"
    ]

    one_of([
      string(:printable, max_length: 30),
      gen(
        all(
          parts <- list_of(member_of(special ++ ["a", ":", ","]), max_length: 20),
          do: Enum.join(parts)
        )
      )
    ])
  end

  # Text as a script may write it: in double or single quotes, as a template,
  # or joined from pieces with `+`, each character written as it is or as an
  # escape.
  defp written_text(text) do
    points = String.to_charlist(text)

    one_of([
      quoted(text, :double),
      quoted(text, :single),
      quoted(text, :template),
      gen all(
            cuts <- list_of(integer(0..length(points)), max_length: 2),
            styles <- list_of(member_of([:double, :single, :template]), length: length(cuts) + 1),
            escapes <- list_of(boolean(), length: length(points)),
            gap <- gap()
          ) do
        cuts
        |> Enum.sort()
        |> pieces(Enum.zip(points, escapes))
        |> Enum.zip(styles)
        |> Enum.map_join(gap <> "+" <> gap, fn {piece, style} -> write(piece, style) end)
      end
    ])
  end

  defp pieces(cuts, points) do
    {pieces, rest, _at} =
      Enum.reduce(cuts, {[], points, 0}, fn cut, {pieces, rest, at} ->
        {piece, rest} = Enum.split(rest, cut - at)
        {[piece | pieces], rest, cut}
      end)

    Enum.reverse([rest | pieces])
  end

  defp quoted(text, style) do
    points = String.to_charlist(text)

    gen all(escapes <- list_of(boolean(), length: length(points))) do
      write(Enum.zip(points, escapes), style)
    end
  end

  defp write(points, style) do
    mark = %{double: "\"", single: "'", template: "`"}[style]
    mark <> Enum.map_join(points, &character(&1, style)) <> mark
  end

  # A character as it must be written in that quoting, or as an escape.
  defp character({c, false}, style) do
    cond do
      c == ?\\ -> "\\\\"
      c == ?\r -> "\\r"
      c == ?\n and style != :template -> "\\n"
      <<c::utf8>> == %{double: "\"", single: "'", template: "`"}[style] -> "\\" <> <<c::utf8>>
      c == ?$ and style == :template -> "\\$"
      true -> <<c::utf8>>
    end
  end

  defp character({c, true}, _style) do
    hex = &(&1 |> Integer.to_string(16) |> String.pad_leading(&2, "0"))

    cond do
      c == ?\n ->
        "\\n"

      c == ?\t ->
        "\\t"

      c == ?\s ->
        "\\\n "

      rem(c, 2) == 0 ->
        "\\u{" <> hex.(c, 1) <> "}"

      c < 0x100 ->
        "\\x" <> hex.(c, 2)

      c <= 0xFFFF ->
        "\\u" <> hex.(c, 4)

      true ->
        c = c - 0x10000
        "\\u" <> hex.(0xD800 + div(c, 0x400), 4) <> "\\u" <> hex.(0xDC00 + rem(c, 0x400), 4)
    end
  end
end
