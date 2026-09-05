defmodule PatchbayWeb.Forum.Fingerprint do
  @moduledoc """
  A digest, shown as colour so it can be recognised without being read.

  Sixty-four hex characters are not something a person reads. Two versions of
  one tool differ somewhere in the middle of them, and a reader comparing two
  rows gives up long before finding where. So the first eight bytes of a digest
  are drawn as four colours as well: two versions look different at arm's
  length, the same version looks the same on every page, and the hex is still
  there beside the colours whenever the exact value is the point.

  The palette is deliberately narrow, and every chip is drawn twice: a deep
  tone for the board's warm paper and a pale one for the same board after
  dark, each far enough from the surface behind it to keep at least 3:1, so
  the chips are legible rather than decorative on either. Hue is the same in
  both and carries most of the difference between two digests; lightness
  carries the rest and is the only thing the two tones disagree about.

  A digest is the canonical 64-character lowercase hex the board stores.
  """

  use Phoenix.Component

  @chip_count 4
  # Each chip reads two bytes: one turns into a hue, the other into a lightness.
  @hex_per_chip 4

  @saturation 55
  # The two readable bands, one per theme, the same width apart from where they
  # start: below the light one everything is darker than the paper it sits on,
  # above the dark one everything is paler than the panel it sits on.
  # `test/patchbay_web/forum/fingerprint_test.exs` checks every colour either
  # band can produce rather than trusting the arithmetic here.
  @lightness_floor 22
  @dark_lightness_floor 60
  @lightness_span 13

  @hue_names ~w(red orange amber lime green teal cyan blue indigo violet magenta rose)

  @short_length 12

  @typedoc "One swatch: the colour to paint in each theme, and the word for it."
  @type chip :: %{light: String.t(), dark: String.t(), name: String.t()}

  @doc """
  The four colours a digest is drawn as, in order.

  The same digest always gives the same four, on every page and every request.
  """
  @spec chips(String.t()) :: [chip()]
  def chips(digest) when is_binary(digest) do
    Enum.map(0..(@chip_count - 1), fn index ->
      <<hue_byte, lightness_byte>> =
        digest
        |> binary_part(index * @hex_per_chip, @hex_per_chip)
        |> Base.decode16!(case: :lower)

      hue = div(hue_byte * 360, 256)
      step = div(lightness_byte * @lightness_span, 256)

      %{
        light: hex_color(hue, @saturation, @lightness_floor + step),
        dark: hex_color(hue, @saturation, @dark_lightness_floor + step),
        name: hue_name(hue)
      }
    end)
  end

  @doc """
  The colours of a digest said out loud, for a reader who cannot see them.

  Example: `"teal, amber, rose, indigo"`.
  """
  @spec label(String.t()) :: String.t()
  def label(digest) when is_binary(digest) do
    digest |> chips() |> Enum.map_join(", ", & &1.name)
  end

  @doc "The opening of a digest, which is as much of it as a row has space for."
  @spec short(String.t()) :: String.t()
  def short(digest) when is_binary(digest), do: String.slice(digest, 0, @short_length) <> "…"

  @doc """
  A digest as its colours and its opening characters together.

  The colours are the glance and the characters are the evidence, so both are
  always shown; the whole digest is on the element for anyone who hovers over
  it or copies it out. Each swatch carries both of its tones and the stylesheet
  picks the one the reader's theme calls for.
  """
  attr(:digest, :string, required: true)

  def fingerprint(assigns) do
    assigns = assign(assigns, chips: chips(assigns.digest), label: label(assigns.digest))

    ~H"""
    <span class="pb-fingerprint" title={@digest}>
      <span class="pb-fingerprint-chips" role="img" aria-label={"Fingerprint colours: " <> @label}>
        <span
          :for={chip <- @chips}
          class="pb-fingerprint-chip"
          style={"--pb-chip-light:#{chip.light};--pb-chip-dark:#{chip.dark}"}
        ></span>
      </span>
      <code class="pb-fingerprint-hex">{short(@digest)}</code>
    </span>
    """
  end

  defp hue_name(hue), do: Enum.at(@hue_names, div(hue, 30))

  # HSL to sRGB, so a colour chosen as a hue and a lightness can be painted and,
  # more to the point, measured for contrast the way a browser sees it.
  defp hex_color(hue, saturation, lightness) do
    s = saturation / 100
    l = lightness / 100
    chroma = (1 - abs(2 * l - 1)) * s
    second = chroma * (1 - abs(:math.fmod(hue / 60, 2) - 1))
    floor = l - chroma / 2

    {red, green, blue} = sextant(hue, chroma, second)

    "#" <> Enum.map_join([red, green, blue], &channel(&1 + floor))
  end

  defp sextant(hue, chroma, second) when hue < 60, do: {chroma, second, 0.0}
  defp sextant(hue, chroma, second) when hue < 120, do: {second, chroma, 0.0}
  defp sextant(hue, chroma, second) when hue < 180, do: {0.0, chroma, second}
  defp sextant(hue, chroma, second) when hue < 240, do: {0.0, second, chroma}
  defp sextant(hue, chroma, second) when hue < 300, do: {second, 0.0, chroma}
  defp sextant(_hue, chroma, second), do: {chroma, 0.0, second}

  defp channel(value) do
    (value * 255)
    |> round()
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(2, "0")
  end
end
