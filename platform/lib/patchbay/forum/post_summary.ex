defmodule Patchbay.Forum.PostSummary do
  @moduledoc """
  What a post says about itself in a line: its own title, the error it is
  about, and the headline its tab title, search description and address are
  made of. One set of rules, so the page, its tab and its address agree.

  A post about an error quotes the error in a code block and says what fixed
  it in a paragraph that starts with a bold **Fix** label.

    * The error is a sentence of the post's first code block that holds one:
      the sentence that shares the most words with the title, the earliest on
      a tie. A block's lines are read as one text, since long errors are
      wrapped over several lines. Commands typed at a prompt (`$ npm install`)
      are not part of the error, and a block with no words left, such as `{}`,
      holds none. A post whose code holds no error, or that has no code, takes
      the first quoted words of its title (`"no_touch_id"`), if any.
    * The headline is the error, then the rest of the title (the title less
      its quoted copy of the error). A post with no error is headed by its
      title.
    * The fix is the first sentence of the first paragraph labelled **Fix**,
      after the label. Without one it is the first sentence after the error's
      code block.

  The tab title is the headline cut between words to 70 characters. The
  description is the error, then the fix, cut between words to 155
  characters; a post whose error is in its title only is described by its
  headline then its first sentence, and a post with no error by its title
  then its first sentence. The fix is left out rather than shown as a stub of
  a few words.
  """

  @description_limit 155
  @title_limit 70
  # The fewest characters of a fix worth showing after the error.
  @least_fix 40

  @doc """
  The post's own title: its title, or for an early report its note, or the
  tool it names on its site, or its site.
  """
  @spec post_title(map()) :: String.t()
  def post_title(report) do
    cond do
      written?(report.title) -> titled(report.title)
      written?(report.note) -> titled(report.note)
      report.tool_names != [] -> "#{hd(report.tool_names)} on #{site_name(report)}"
      true -> site_name(report)
    end
  end

  @doc "The page's tab title: the headline, cut between words to #{@title_limit} characters."
  @spec title(map()) :: String.t()
  def title(post), do: post |> headline() |> cut(@title_limit)

  @doc "The error first, then the rest of the post's title; the title alone when there is no error."
  @spec headline(map()) :: String.t()
  def headline(post) do
    title = post_title(post)

    case error_in(code_blocks(post), title) do
      nil -> title
      {_error, _after} = found -> headed(found, title)
    end
  end

  @doc "The page's search description, never empty."
  @spec description(map()) :: String.t()
  def description(post) do
    blocks = blocks(post)
    title = post_title(post)

    case error_in(blocks, title) do
      nil -> join(title, first_sentence(prose(blocks)))
      {error, {:code, after_error}} -> join(error, fix(blocks, after_error))
      {_error, :title} = found -> join(headed(found, title), fix(blocks, blocks))
    end
  end

  @doc "The error the post is about, word for word, or nil when it names none."
  @spec error(map()) :: String.t() | nil
  def error(post) do
    case error_in(code_blocks(post), post_title(post)) do
      nil -> nil
      {error, _where} -> error
    end
  end

  # The error and where it was found: in a code block (with the blocks after
  # it), or in the title.
  defp error_in(blocks, title) do
    wanted = words(title)

    blocks
    |> Enum.with_index()
    |> Enum.find_value(fn
      {{:code, text}, index} ->
        with error when is_binary(error) <- chosen(text, wanted),
             do: {error, {:code, Enum.drop(blocks, index + 1)}}

      _paragraph ->
        nil
    end)
    |> case do
      nil -> quoted(title)
      found -> found
    end
  end

  defp chosen(text, wanted) do
    case sentences(text) do
      [] ->
        nil

      sentences ->
        sentences
        |> Enum.with_index()
        |> Enum.max_by(fn {sentence, index} -> {overlap(sentence, wanted), -index} end)
        |> elem(0)
        |> without_marks()
        |> worded()
    end
  end

  # The first quoted words of the title.
  defp quoted(title) do
    case Regex.run(~r/["“]([^"“”]+)["”]/u, title, capture: :all_but_first) do
      [words] -> with error when is_binary(error) <- worded(squash(words)), do: {error, :title}
      nil -> nil
    end
  end

  defp worded(text), do: if(text =~ ~r/[\p{L}\p{N}]/u, do: text)

  # The error, then the title without its quoted copy of the error.
  defp headed({error, _where}, title) do
    rest =
      title
      |> String.replace(["\"#{error}\"", "“#{error}”"], " ")
      |> squash()
      |> String.replace(~r/^[\s,;:—-]+|[\s,;:—-]+$/u, "")

    cond do
      rest == "" -> error
      String.match?(error, ~r/[.!?]$/u) -> error <> " " <> rest
      true -> error <> " — " <> rest
    end
  end

  # The fix's first sentence, after its label; or, when there is no labelled
  # fix with words of its own, the first sentence of `after_error`.
  defp fix(blocks, after_error) do
    case Enum.find(blocks, &match?({:paragraph, "fix" <> _label, _words}, &1)) do
      {:paragraph, _label, words} when words != "" -> "Fix: " <> first_sentence(words)
      _no_fix -> after_error |> prose() |> first_sentence()
    end
  end

  # The blocks the error is looked for in. Reading Markdown takes a fixed
  # fraction of a millisecond however short the text, and every link to the
  # post needs its error, so a body that cannot hold a top-level code block (a
  # fence, or a line indented four spaces) is not read for one.
  defp code_blocks(%{body_markdown: body} = post) when is_binary(body) do
    if body =~ ~r/^ {0,3}(?:```|~~~|\t)|^ {4}/m, do: blocks(post), else: []
  end

  defp code_blocks(_post), do: []

  # The post's top-level blocks: each code block's text without the commands
  # typed at a prompt, and each paragraph's leading bold label (lowercased,
  # for matching) and the words after it. A page asks for the same post's
  # blocks many times over (each link to it, its title, its description), so
  # the last body read is kept for the process that read it.
  defp blocks(%{body_markdown: body}) when is_binary(body) and body != "" do
    case Process.get(__MODULE__) do
      {^body, blocks} ->
        blocks

      _other ->
        blocks = read(body)
        Process.put(__MODULE__, {body, blocks})
        blocks
    end
  end

  defp blocks(%{note: note}) when is_binary(note), do: [{:paragraph, "", squash(note)}]
  defp blocks(_post), do: []

  defp read(body) do
    body
    |> MDEx.parse_document!()
    |> Map.fetch!(:nodes)
    |> Enum.flat_map(fn
      %MDEx.CodeBlock{literal: text} ->
        case text
             |> String.split("\n")
             |> Enum.reject(&command?/1)
             |> Enum.join(" ")
             |> squash() do
          "" -> []
          printed -> [{:code, printed}]
        end

      %MDEx.Paragraph{nodes: nodes} ->
        [paragraph(nodes)]

      _other ->
        []
    end)
  end

  # A line typed at a shell prompt: `$ `, `% `, `# `, `> `, `>>> `, `PS C:\>`
  # or `name@host:~$ `.
  defp command?(line),
    do: line =~ ~r/^\s*(?:>>>|[$%#>]|PS [^>]*>|[\w.-]+@[\w.-]+(?::\S*?)?[$#%])(?:\s|$)/u

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

  # A tool's marks before its message, such as a failed check's cross, are
  # not part of the error's words.
  defp without_marks(sentence), do: String.replace(sentence, ~r/^[^\p{L}\p{N}"'(\[]+/u, "")

  defp squash(text), do: text |> String.split() |> Enum.join(" ")

  defp written?(text), do: is_binary(text) and String.trim(text) != ""

  defp titled(text) do
    {text, cut?} = Patchbay.BoundedText.take(String.trim(text), 160)
    if cut?, do: text <> "…", else: text
  end

  # The site's name, read when the post was read without its site.
  defp site_name(%{site: %Ash.NotLoaded{}} = report),
    do: report |> Ash.load!(:site, authorize?: false) |> site_name()

  defp site_name(%{site: site}), do: site.display_name || site.origin

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
