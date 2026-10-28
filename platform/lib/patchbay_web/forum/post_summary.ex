defmodule PatchbayWeb.Forum.PostSummary do
  @moduledoc """
  What a post's page tells search engines in its tab title and description.

  A post about an error quotes the error in a code block and says what fixed
  it in a paragraph that starts with a bold **Fix** label. The description is
  that error, word for word, then the fix:

    * The error is the sentence of the post's first code block that shares the
      most words with the title (the title leads with the error), the
      earliest on a tie. A block's lines are read as one text, since long
      errors are wrapped over several lines.
    * The fix is the first sentence of the first paragraph labelled **Fix**,
      after the label. When that paragraph has no words of its own, it is the
      first sentence after the code block instead.
    * A post with no code block is described by its title and its first
      sentence.

  The description is cut between words to 155 characters. The fix is left
  out rather than shown as a stub of a few words.
  """

  alias PatchbayWeb.Forum.BoardHTML

  @description_limit 155
  @title_limit 70
  # The fewest characters of a fix worth showing after the error.
  @least_fix 40

  @doc "The page's tab title: the post's title, cut between words to #{@title_limit} characters."
  @spec title(map()) :: String.t()
  def title(post), do: post |> BoardHTML.post_title() |> cut(@title_limit)

  @doc "The page's search description: the error, then the fix."
  @spec description(map()) :: String.t()
  def description(post) do
    blocks = blocks(post)
    title = BoardHTML.post_title(post)

    case error(blocks, title) do
      nil -> join(title, first_sentence(prose(blocks)))
      error -> join(error, fix(blocks))
    end
  end

  @doc "The error the post quotes, word for word, or nil when it quotes none."
  @spec error(map()) :: String.t() | nil
  def error(post), do: error(blocks(post), BoardHTML.post_title(post))

  defp error(blocks, title) do
    case Enum.find(blocks, &match?({:code, _}, &1)) do
      nil ->
        nil

      {:code, text} ->
        wanted = words(title)

        text
        |> sentences()
        |> Enum.with_index()
        |> Enum.max_by(fn {sentence, index} -> {overlap(sentence, wanted), -index} end)
        |> elem(0)
        |> without_marks()
    end
  end

  # The fix's first sentence, after its label; or, when the paragraph has no
  # words of its own, the first sentence after the error's code block.
  defp fix(blocks) do
    case Enum.find(blocks, &match?({:paragraph, "fix" <> _label, _words}, &1)) do
      {:paragraph, _label, words} when words != "" ->
        "Fix: " <> first_sentence(words)

      _no_fix ->
        blocks
        |> Enum.drop_while(&(not match?({:code, _}, &1)))
        |> Enum.drop(1)
        |> prose()
        |> first_sentence()
    end
  end

  # The post's top-level blocks: each code block's text, and each paragraph's
  # leading bold label (lowercased, for matching) and the words after it.
  defp blocks(%{body_markdown: body}) when is_binary(body) and body != "" do
    body
    |> MDEx.parse_document!()
    |> Map.fetch!(:nodes)
    |> Enum.flat_map(fn
      %MDEx.CodeBlock{literal: text} ->
        if squash(text) == "", do: [], else: [{:code, squash(text)}]

      %MDEx.Paragraph{nodes: nodes} ->
        [paragraph(nodes)]

      _other ->
        []
    end)
  end

  defp blocks(%{note: note}) when is_binary(note), do: [{:paragraph, "", squash(note)}]
  defp blocks(_post), do: []

  defp paragraph([%MDEx.Strong{} = label | rest]),
    do: {:paragraph, label |> text() |> String.downcase(), rest |> text() |> squash()}

  defp paragraph(nodes), do: {:paragraph, "", nodes |> text() |> squash()}

  defp text(nodes) do
    nodes
    |> List.wrap()
    |> Enum.flat_map(fn
      %struct{literal: literal} when struct in [MDEx.Text, MDEx.Code] -> [literal]
      %struct{} when struct in [MDEx.SoftBreak, MDEx.LineBreak] -> [" "]
      %{nodes: inner} -> [text(inner)]
      _other -> []
    end)
    |> Enum.join()
  end

  defp prose(blocks) do
    Enum.find_value(blocks, "", fn
      {:paragraph, _label, words} when words != "" -> words
      _other -> nil
    end)
  end

  defp sentences(text), do: String.split(text, ~r/(?<=[.!?])\s+/u, trim: true)

  defp first_sentence(""), do: ""
  defp first_sentence(text), do: text |> sentences() |> hd()

  defp words(text) do
    ~r/[\p{L}\p{N}_]+/u
    |> Regex.scan(String.downcase(text))
    |> List.flatten()
    |> MapSet.new()
  end

  defp overlap(sentence, wanted),
    do: sentence |> words() |> MapSet.intersection(wanted) |> MapSet.size()

  # A tool's marks before its message, such as a prompt's `$` or a failed
  # check's cross, are not part of the error's words.
  defp without_marks(sentence), do: String.replace(sentence, ~r/^[^\p{L}\p{N}"'(\[]+/u, "")

  defp squash(text), do: text |> String.split() |> Enum.join(" ")

  # The lead, then as much of the rest as fits; a rest that would show fewer
  # than @least_fix characters is left out. A rest the lead already says is
  # not said twice.
  defp join(lead, rest) do
    lead = squash(lead)
    rest = squash(rest)

    # A lead that is not a whole sentence, such as an error quoted as it was
    # printed, is set apart from the rest with a dash rather than changed.
    gap = if String.match?(lead, ~r/[.!?]$/u), do: " ", else: " — "
    room = @description_limit - String.length(lead) - String.length(gap)

    if rest == "" or room < @least_fix or String.contains?(lead, rest),
      do: cut(lead, @description_limit),
      else: lead <> gap <> cut(rest, room)
  end

  # Cut between words to at most `limit` characters, the ellipsis included.
  defp cut(text, limit) do
    if String.length(text) <= limit do
      text
    else
      kept = String.slice(text, 0, limit - 1)

      # The last word is whole only when a space follows it.
      kept =
        case {String.at(text, limit - 1) =~ ~r/\s/u, String.split(kept, ~r/\s+(?=\S*$)/u)} do
          {true, _words} -> kept
          {false, [whole]} -> whole
          {false, [head, _partial_word]} -> head
        end

      String.replace(kept, ~r/[\s,;:]+$/u, "") <> "…"
    end
  end
end
