defmodule PatchbayWeb.Forum.FingerprintTest do
  use ExUnit.Case, async: true

  alias PatchbayWeb.Forum.Fingerprint

  # The paper a chip is read against, and the warmer paper a version row sits
  # on. A chip has to hold up on both.
  @surface "#fffdf8"
  @version_row "#fbf8f2"

  # Graphics that carry meaning have to reach 3:1 against what is behind them.
  @readable 3.0

  defp digest(seed), do: seed |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  describe "the colours a digest is drawn as" do
    test "one digest always gives the same four colours" do
      chips = Fingerprint.chips(digest("checkout"))

      assert length(chips) == 4
      assert chips == Fingerprint.chips(digest("checkout"))
      assert Enum.all?(chips, &(&1.color =~ ~r/\A#[0-9a-f]{6}\z/))
    end

    test "two digests that differ in their opening bytes are drawn differently" do
      one = String.duplicate("a", 64)
      other = "b" <> String.duplicate("a", 63)

      refute Fingerprint.chips(one) == Fingerprint.chips(other)
    end

    test "only the opening of a digest is drawn, so the rest cannot change it" do
      opening = String.duplicate("3f", 8)

      assert Fingerprint.chips(opening <> String.duplicate("0", 48)) ==
               Fingerprint.chips(opening <> String.duplicate("c", 48))
    end

    test "the colours are named in order, for a reader who cannot see them" do
      # 00 is a red hue, 55 a lime one, aa a blue one and ff a rose one.
      digest = "0000" <> "5500" <> "aa00" <> "ff00" <> String.duplicate("0", 48)

      assert Fingerprint.label(digest) == "red, lime, blue, rose"
    end

    test "the hex is shown from the front, so it can be matched against a record" do
      assert Fingerprint.short(String.duplicate("a", 64)) == String.duplicate("a", 12) <> "…"
    end
  end

  describe "how readable the colours are" do
    test "every colour a digest could ever produce stays readable on the board" do
      # There are 65,536 of them: one for each hue byte against each lightness
      # byte. Checking all of them is cheap, and it makes the band a fact
      # rather than an intention.
      readings =
        for hue_byte <- 0..255, lightness_byte <- 0..255 do
          [chip | _rest] = Fingerprint.chips(opening(hue_byte, lightness_byte))
          {min(contrast(chip.color, @surface), contrast(chip.color, @version_row)), chip.color}
        end

      {ratio, color} = Enum.min(readings)

      assert ratio >= @readable,
             "#{color} only reaches #{Float.round(ratio, 2)}:1 against the board's paper"
    end

    test "even the darkest colours still carry a hue rather than reading as black" do
      # Four near-black swatches would be readable and useless: the run has to
      # tell one digest from another, which takes visible colour.
      for hue_byte <- 0..255 do
        channels = channels_of(hd(Fingerprint.chips(opening(hue_byte, 0x00))).color)

        assert Enum.max(channels) - Enum.min(channels) >= 0x30
      end
    end
  end

  defp opening(hue_byte, lightness_byte) do
    Base.encode16(<<hue_byte, lightness_byte>>, case: :lower) <> String.duplicate("0", 60)
  end

  # WCAG 2.2 contrast, written out here rather than imported, so the check is
  # independent of the code that chose the colour.
  defp contrast(one, other) do
    [bright, dim] = Enum.sort([luminance(one), luminance(other)], :desc)
    (bright + 0.05) / (dim + 0.05)
  end

  defp luminance(color) do
    [red, green, blue] = Enum.map(channels_of(color), &linear(&1 / 255))

    0.2126 * red + 0.7152 * green + 0.0722 * blue
  end

  defp channels_of("#" <> hex) do
    for offset <- [0, 2, 4], do: hex |> String.slice(offset, 2) |> String.to_integer(16)
  end

  defp linear(channel) when channel <= 0.03928, do: channel / 12.92
  defp linear(channel), do: :math.pow((channel + 0.055) / 1.055, 2.4)
end
