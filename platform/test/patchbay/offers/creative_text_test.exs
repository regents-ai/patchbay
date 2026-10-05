defmodule Patchbay.Offers.CreativeTextTest do
  use ExUnit.Case, async: true

  alias Patchbay.Offers.CreativeText

  doctest CreativeText

  test "ordinary text with a link is kept exactly" do
    text = "Hosted MCP for your tools, 5 USDC a month: https://example.com/start"

    assert CreativeText.normalize(text) == {:ok, text}
  end

  test "text is normalized to NFC and kept as normalized" do
    decomposed = "Cafe\u{301} tools"

    assert CreativeText.normalize(decomposed) == {:ok, "Caf\u{E9} tools"}
  end

  test "160 code points are allowed and 161 are not" do
    assert {:ok, _} = CreativeText.normalize(String.duplicate("a", 160))
    assert CreativeText.normalize(String.duplicate("a", 161)) == {:error, :too_long}
  end

  test "code points are counted, not graphemes" do
    # One grapheme, two code points that NFC keeps apart.
    flag = "\u{1F1EB}\u{1F1F7}"
    assert {:ok, _} = CreativeText.normalize(String.duplicate(flag, 80))
    assert CreativeText.normalize(String.duplicate(flag, 80) <> "a") == {:error, :too_long}
  end

  test "160 four-byte code points fill the 640 bytes exactly" do
    # No code point is longer than four bytes, so text within 160 code points
    # is always within 640 bytes; the byte limit stands as the stored rule.
    text = String.duplicate("\u{1F600}", 160)

    assert byte_size(text) == 640
    assert CreativeText.normalize(text) == {:ok, text}
    assert CreativeText.normalize(text <> "\u{1F600}") == {:error, :too_long}
  end

  test "combining marks count as code points" do
    text = String.duplicate("a\u{332}", 80)

    assert {:ok, ^text} = CreativeText.normalize(text)
    assert CreativeText.normalize(text <> "b") == {:error, :too_long}
  end

  test "blank text and invalid UTF-8 are refused" do
    assert CreativeText.normalize("   ") == {:error, :blank}
    assert CreativeText.normalize("") == {:error, :blank}
    assert CreativeText.normalize(<<0xFF, 0xFE>>) == {:error, :invalid_utf8}
    assert CreativeText.normalize(nil) == {:error, :invalid_utf8}
  end

  test "more than one line is refused" do
    for separator <- ["\n", "\r", "\u0085", "\u{2028}", "\u{2029}"] do
      assert CreativeText.normalize("one" <> separator <> "two") == {:error, :not_one_line}
    end
  end

  test "controls, bidirectional and invisible characters are refused" do
    for char <- [
          "\t",
          "\u0000",
          "\u007F",
          "\u{202E}",
          "\u{2066}",
          "\u{200B}",
          "\u{200D}",
          "\u{2060}",
          "\u{FEFF}",
          "\u{AD}",
          "\u{FE0F}",
          "\u{E0041}",
          "\u{34F}",
          "\u{FDD0}",
          "\u{FFFE}"
        ] do
      assert CreativeText.normalize("a" <> char <> "b") == {:error, :invisible_or_control},
             inspect(char)
    end
  end

  test "only the ordinary space is allowed" do
    for space <- ["\u{A0}", "\u{2003}", "\u{3000}", "\u{202F}"] do
      assert CreativeText.normalize("a" <> space <> "b") == {:error, :unusual_space}
    end
  end

  test "markup is kept as literal text" do
    text = "<b>bold</b> **not markdown** &amp;"

    assert CreativeText.normalize(text) == {:ok, text}
  end

  test "every full link is found, and punctuation after it is left out" do
    text = "See https://a.dev/x), then http://b.dev/y?z=1. Done"

    assert CreativeText.urls(text) == ["https://a.dev/x", "http://b.dev/y?z=1"]
  end

  test "segments put the text back together exactly" do
    text = "Start at https://a.dev/x, or https://b.dev."
    segments = CreativeText.segments(text)

    assert Enum.map_join(segments, fn {_kind, piece} -> piece end) == text
    assert for({:url, url} <- segments, do: url) == ["https://a.dev/x", "https://b.dev"]
  end

  test "bare addresses are reported, full links are not" do
    assert CreativeText.bare_addresses("Go to example.com/start or https://ok.dev") == [
             "example.com/start"
           ]

    assert CreativeText.bare_addresses("Email me@example.com") == []
  end
end
