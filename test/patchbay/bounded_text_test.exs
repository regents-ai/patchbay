defmodule Patchbay.BoundedTextTest do
  use ExUnit.Case, async: true

  alias Patchbay.BoundedText

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
