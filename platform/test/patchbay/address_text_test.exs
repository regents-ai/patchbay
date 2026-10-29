defmodule Patchbay.AddressTextTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Patchbay.AddressText

  doctest AddressText

  @a "0x1234567890abcdef1234567890ABCDEF12345678"
  @b "0x" <> String.duplicate("e", 40)

  property "cutting words keeps every character in order, with each address whole" do
    check all(
            parts <-
              list_of(one_of([constant({:address, @a}), constant({:address, @b}), words()]),
                max_length: 8
              )
          ) do
      # Something always stands between two addresses, as it does in writing.
      text =
        Enum.map_join(parts, fn
          {:address, a} -> " " <> a <> " "
          words -> words
        end)

      pieces = AddressText.split(text)

      assert Enum.map_join(pieces, fn
               {:address, a} -> a
               words -> words
             end) == text

      assert for({:address, a} <- pieces, do: a) ==
               for({:address, a} <- parts, do: a)
    end
  end

  test "a longer hex string is not an address" do
    assert AddressText.split(@a <> "9") == [@a <> "9"]
  end

  test "markdown keeps its HTML and cuts out addresses in words and inline code, never in a code block" do
    document =
      MDEx.parse_document!("""
      Paid to #{@a}, then `#{@b}`.

      ```
      send to #{@a}
      ```
      """)

    pieces = AddressText.html(document)

    assert [
             {:html, "<p>Paid to "},
             {:address, @a},
             {:html, ", then "},
             {:address, @b},
             {:html, ".</p>\n<pre><code>send to " <> @a <> "\n</code></pre>"}
           ] = pieces
  end

  defp words do
    map(string([?a..?z, ?\s, ?,, ?.], min_length: 1, max_length: 12), &(" " <> &1 <> " "))
  end
end
