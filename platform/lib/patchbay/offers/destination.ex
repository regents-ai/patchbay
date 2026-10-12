defmodule Patchbay.Offers.Destination do
  @moduledoc """
  Visits one link in an Offer to see where it really goes.

  Every hop goes through `Patchbay.Assist.Target`: a public `https` name on
  port 443, resolved and checked to be on the public internet, connected to
  at the checked address, with no cookies, no credentials and a bounded
  answer. A redirect is followed by hand, each new address checked the same
  way, up to three times. A plain `http` link, or a redirect to one, is not
  visited and is left for a moderator.

  What comes back is evidence for screening: every hop, the final status, a
  hash of what was read and the page's title. A page longer than is read is
  noted as `too_long`, so a moderator sees it. A short excerpt of the page's
  words goes to the screening question and is never kept or shown.
  """

  alias Patchbay.Assist.Target

  @max_redirects 3
  @max_body_bytes 256 * 1024
  @fetch_timeout_ms 10_000
  @excerpt_chars 1_500
  @title_chars 200

  @type evidence :: %{String.t() => term()}

  @doc """
  Where `url` leads: the evidence to keep, and the excerpt to screen.
  `opts` are `Patchbay.Assist.Target.connect/2`'s.
  """
  @spec visit(String.t(), keyword()) :: {evidence(), String.t() | nil}
  def visit(url, opts \\ []), do: follow(url, [url], opts)

  defp follow(url, hops, opts) do
    case get(url, opts) do
      {:ok, status, location, _type, _body, _cut?}
      when status in [301, 302, 303, 307, 308] and is_binary(location) ->
        redirect(hops, status, url |> URI.merge(location) |> URI.to_string(), opts)

      {:ok, status, _location, type, body, cut?} when status in 200..299 ->
        read(hops, status, type, body, cut?)

      {:ok, status, _location, _type, _body, _cut?} ->
        {ended(hops, "unreadable", status), nil}

      {:error, reason} when reason in [:not_https, :not_public] ->
        {ended(hops, Atom.to_string(reason), nil), nil}

      {:error, _unreachable} ->
        {ended(hops, "unreadable", nil), nil}
    end
  end

  defp redirect(hops, status, next, opts) do
    cond do
      length(hops) > @max_redirects -> {ended(hops, "too_many_redirects", status), nil}
      not https?(next) -> {ended(hops ++ [next], "not_https", status), nil}
      true -> follow(next, hops ++ [next], opts)
    end
  end

  defp get(url, opts) do
    with true <- https?(url) || {:error, :not_https},
         {:ok, target} <- Target.connect(url, Keyword.put(opts, :max_body_bytes, @max_body_bytes)),
         {:ok, %Req.Response{} = response} <-
           Req.get(
             target.url,
             [compressed: false, receive_timeout: @fetch_timeout_ms] ++ target.options
           ) do
      {:ok, response.status, header(response, "location"), header(response, "content-type") || "",
       response.body |> Kernel.||("") |> IO.iodata_to_binary(),
       Map.get(response.private, :assist_cut, false)}
    else
      {:error, reason} when reason in [:not_https, :not_public] -> {:error, reason}
      _failed -> {:error, :unreachable}
    end
  end

  # A page or plain text is read for its words; anything else, such as a
  # download, is left for a moderator. A page cut at the bound may end inside
  # a character, so only its whole characters are read.
  defp read(hops, status, type, body, cut?) do
    body = if cut?, do: whole_characters(body), else: body

    if type =~ ~r/\A\s*text\/(html|plain)/i and String.valid?(body) do
      words = words(body)

      evidence =
        hops
        |> ended(if(cut?, do: "too_long", else: "read"), status)
        |> Map.merge(%{
          "content_sha256" => :crypto.hash(:sha256, body) |> Base.encode16(case: :lower),
          "title" => title(body)
        })

      {evidence, String.slice(words, 0, @excerpt_chars)}
    else
      {ended(hops, "not_a_page", status), nil}
    end
  end

  defp whole_characters(body) do
    case :unicode.characters_to_binary(body) do
      {:incomplete, whole, _partial} -> whole
      _whole_or_invalid -> body
    end
  end

  defp ended(hops, outcome, status) do
    %{
      "url" => hd(hops),
      "hops" => hops,
      "final_url" => List.last(hops),
      "status" => status,
      "outcome" => outcome
    }
  end

  defp https?(url), do: match?(%URI{scheme: "https"}, URI.parse(url))

  defp header(response, name), do: response |> Req.Response.get_header(name) |> List.first()

  defp title(html) do
    case Regex.run(~r/<title[^>]*>(.*?)<\/title>/is, html, capture: :all_but_first) do
      [title] -> title |> collapse() |> String.slice(0, @title_chars)
      nil -> nil
    end
  end

  defp words(html) do
    html
    |> String.replace(~r/<(script|style|noscript)\b.*?<\/\1>/is, " ")
    |> String.replace(~r/<[^>]*>/s, " ")
    |> collapse()
  end

  defp collapse(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()
end
