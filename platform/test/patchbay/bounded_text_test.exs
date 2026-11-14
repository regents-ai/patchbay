defmodule Patchbay.BoundedTextTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Patchbay.BoundedText

  property "cut text fits its budget, ends with … and keeps only whole words but for one too long" do
    word = string([?a..?z, ?é, ?😀], min_length: 1, max_length: 12)
    space = member_of([" ", "  ", "\n", "\t", ", ", ". ", "; "])

    check all(
            parts <- list_of(tuple({word, space}), min_length: 1, max_length: 40),
            limit <- integer(1..120)
          ) do
      text = Enum.map_join(parts, fn {word, space} -> word <> space end)
      cut = BoundedText.cut(text, limit)

      if String.length(text) <= limit do
        assert cut == text
      else
        assert String.length(cut) <= limit
        assert String.ends_with?(cut, "…")

        kept = String.trim_trailing(cut, "…")
        assert String.starts_with?(text, kept)

        # What is kept stops at the end of a word, unless it is the start of a
        # first word too long for the budget; a budget of one has room for
        # the "…" alone.
        rest = binary_part(text, byte_size(kept), byte_size(text) - byte_size(kept))
        first_word = text |> String.split(~r/[\s,.;]+/u) |> hd()

        assert (limit == 1 and kept == "") or rest =~ ~r/\A[\s,.;]/u or
                 (kept != "" and String.starts_with?(first_word, kept) and
                    String.length(first_word) >= limit)
      end
    end
  end

  test "text exactly at the budget is handed back whole" do
    text = String.duplicate("a", 10)

    assert BoundedText.take(text, 10) == {text, false}
  end

  test "one byte over the budget is cut to the budget" do
    assert BoundedText.take(String.duplicate("a", 11), 10) == {String.duplicate("a", 10), true}
  end

  test "a cut landing inside a character drops the part of it that is left" do
    # Every "é" is two bytes, so a five-byte cut lands halfway through the third.
    assert BoundedText.take(String.duplicate("é", 6), 5) == {"éé", true}
  end

  test "a cut landing on a character boundary keeps every whole character" do
    assert BoundedText.take(String.duplicate("é", 6), 4) == {"éé", true}
  end

  test "multi-byte text inside the budget is left alone" do
    text = String.duplicate("é", 6)

    assert BoundedText.take(text, 12) == {text, false}
  end

  test "empty text is inside every budget" do
    assert BoundedText.take("", 1) == {"", false}
  end
end
