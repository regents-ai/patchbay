defmodule Patchbay.Offers.CreativeText do
  @moduledoc """
  The one rule for an Offer's text, used by every door that saves one.

  The text is normalized once to NFC and kept exactly as normalized: it is
  never cut short or rewritten. It must be one line of plain text, at most 160
  Unicode code points and 640 UTF-8 bytes, including any links.

  The character policy, applied after normalization:

    * every control character, format character (which covers bidirectional
      overrides and isolates and zero-width characters), line separator,
      paragraph separator and surrogate is refused;
    * every default-ignorable code point is refused, including variation
      selectors and the zero-width joiner, so an emoji written with them is
      refused too;
    * every noncharacter is refused;
    * the ordinary space is the only space allowed.

  Links are found by `urls/1`, the same parser the pages use to make links,
  so what is reviewed and what is linked can never differ. Only links written
  in full with `http://` or `https://` count; a bare address such as
  `example.com` is reported by `bare_addresses/1` so review can look at it.
  """

  @max_code_points 160
  @max_bytes 640

  @doc "The most code points an Offer's text may have."
  @spec max_code_points() :: pos_integer()
  def max_code_points, do: @max_code_points

  @doc "The most UTF-8 bytes an Offer's text may have."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  The normalized text, or the reason it can't be an Offer.

  Reasons: `:invalid_utf8`, `:blank`, `:too_long` (more than 160 code
  points), `:too_many_bytes` (more than 640 bytes), `:not_one_line`,
  `:invisible_or_control`, `:unusual_space`.
  """
  @spec normalize(term()) :: {:ok, String.t()} | {:error, atom()}
  def normalize(text) when is_binary(text) do
    with :ok <- valid_utf8(text),
         normalized = String.normalize(text, :nfc),
         :ok <- not_blank(normalized),
         :ok <- one_line(normalized),
         :ok <- visible(normalized),
         :ok <- ordinary_spaces(normalized),
         :ok <- within_code_points(normalized),
         :ok <- within_bytes(normalized) do
      {:ok, normalized}
    end
  end

  def normalize(_other), do: {:error, :invalid_utf8}

  @doc "The number of Unicode code points in already-normalized `text`."
  @spec code_points(String.t()) :: non_neg_integer()
  def code_points(text), do: text |> String.codepoints() |> length()

  defp valid_utf8(text), do: if(String.valid?(text), do: :ok, else: {:error, :invalid_utf8})

  defp not_blank(text), do: if(String.trim(text) == "", do: {:error, :blank}, else: :ok)

  defp one_line(text) do
    if Regex.match?(~r/[\n\r\x{0085}\x{2028}\x{2029}]/u, text),
      do: {:error, :not_one_line},
      else: :ok
  end

  # Controls, format characters, separators and surrogates by category; the
  # default-ignorable code points and noncharacters that fall outside those
  # categories by range.
  @invisible ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Cs}\x{034F}\x{115F}\x{1160}\x{17B4}\x{17B5}\x{180B}-\x{180F}\x{3164}\x{FE00}-\x{FE0F}\x{FFA0}\x{FFF0}-\x{FFF8}\x{1BCA0}-\x{1BCA3}\x{1D173}-\x{1D17A}\x{E0000}-\x{E0FFF}\x{FDD0}-\x{FDEF}\x{FFFE}\x{FFFF}\x{1FFFE}\x{1FFFF}\x{2FFFE}\x{2FFFF}\x{3FFFE}\x{3FFFF}\x{4FFFE}\x{4FFFF}\x{5FFFE}\x{5FFFF}\x{6FFFE}\x{6FFFF}\x{7FFFE}\x{7FFFF}\x{8FFFE}\x{8FFFF}\x{9FFFE}\x{9FFFF}\x{AFFFE}\x{AFFFF}\x{BFFFE}\x{BFFFF}\x{CFFFE}\x{CFFFF}\x{DFFFE}\x{DFFFF}\x{EFFFE}\x{EFFFF}\x{FFFFE}\x{FFFFF}\x{10FFFE}\x{10FFFF}]/u

  defp visible(text),
    do: if(Regex.match?(@invisible, text), do: {:error, :invisible_or_control}, else: :ok)

  defp ordinary_spaces(text) do
    if Regex.match?(~r/(?! )\p{Zs}/u, text), do: {:error, :unusual_space}, else: :ok
  end

  defp within_code_points(text),
    do: if(code_points(text) > @max_code_points, do: {:error, :too_long}, else: :ok)

  defp within_bytes(text),
    do: if(byte_size(text) > @max_bytes, do: {:error, :too_many_bytes}, else: :ok)

  @url ~r/https?:\/\/[^\s<>"'`]+/iu
  @closing_punctuation ~r/[.,;:!?)\]}]+\z/u

  @doc """
  Every link written in full in `text`, in order, with sentence punctuation
  after it left out.

      iex> Patchbay.Offers.CreativeText.urls("Try https://example.com/a, or http://x.dev.")
      ["https://example.com/a", "http://x.dev"]
  """
  @spec urls(String.t()) :: [String.t()]
  def urls(text) do
    @url
    |> Regex.scan(text)
    |> Enum.map(fn [url] -> String.replace(url, @closing_punctuation, "") end)
    |> Enum.reject(&(&1 in ["http://", "https://"]))
  end

  @doc """
  The text split into plain pieces and links, in order, for a page to show
  with each link made clickable and every other piece as plain text.

      iex> Patchbay.Offers.CreativeText.segments("See https://a.dev now")
      [{:text, "See "}, {:url, "https://a.dev"}, {:text, " now"}]
  """
  @spec segments(String.t()) :: [{:text | :url, String.t()}]
  def segments(text) do
    text
    |> urls()
    |> Enum.reduce({[], text}, fn url, {acc, rest} ->
      [before, after_url] = String.split(rest, url, parts: 2)
      {[{:url, url}, {:text, before} | acc], after_url}
    end)
    |> then(fn {acc, rest} -> Enum.reverse([{:text, rest} | acc]) end)
    |> Enum.reject(&match?({:text, ""}, &1))
  end

  @bare_address ~r/(?<![\w@\/.-])(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}(?::\d+)?(?:\/\S*)?/iu

  @doc """
  Address-like words that are not full links, such as `example.com/start`.
  Review looks at each one; they are never made into links.

      iex> Patchbay.Offers.CreativeText.bare_addresses("Visit example.com or https://ok.dev")
      ["example.com"]
  """
  @spec bare_addresses(String.t()) :: [String.t()]
  def bare_addresses(text) do
    without_urls = Enum.reduce(urls(text), text, &String.replace(&2, &1, " "))

    @bare_address
    |> Regex.scan(without_urls)
    |> Enum.map(fn [address] -> String.replace(address, @closing_punctuation, "") end)
  end
end
