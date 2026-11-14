defmodule Patchbay.Assist.ObjectLiterals do
  @moduledoc """
  The object literals a script writes, each with its own keys, read the way a
  JavaScript parser reads the script and without running any of it.

  A key's value is `{:text, text}` when the script writes it as text that can
  be known without running anything: a string, or a template with nothing
  put into it, or several of them joined with `+`, every escape read as
  JavaScript reads it. Anything else (a number, a call, a variable, an
  object, a template that puts a value into its text) is `:code`.

  Only an object's own keys are its own: the keys of an object written inside
  it belong to that inner object, which is listed by itself. Strings,
  templates, comments and regular expressions are read whole, so the
  brackets and quotes inside them are never taken for the script's own. A `/`
  starts a regular expression where a value could start, and divides
  anywhere else, as a parser decides. A line break ends a string, as it ends
  one that was never closed, so a misread quote cannot swallow the rest of
  the script. A script that is not valid JavaScript is read as far as it
  goes; an object it never closes is not listed.

  Braces that hold statements, such as a function's body, are read as an
  object too: what such a block holds seldom pairs a key with text, so a
  caller looking for particular keys passes over it.
  """

  @type value :: {:text, String.t()} | :code
  @type object :: %{String.t() => value()}

  # After these words a value starts, so a `/` starts a regular expression.
  @value_starts ~w(return typeof instanceof in of new delete void throw case do else yield await)

  # No page nests brackets this deep; a script that does is read up to there.
  @deepest 256
  # The most hex digits, braces and all, a `\u{…}` escape is read for.
  @longest_point 12

  defguardp word?(c) when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?_, ?$] or c >= 0x80

  @doc "Every object literal `code` writes and closes, with its own keys, in the order each closes."
  @spec read(binary()) :: [object()]
  def read(code) when is_binary(code), do: scan(code, :start, [], [])

  ## The script, a token at a time
  #
  # `prev` is `:value` after something a `/` would divide, `:start` where a
  # value could start. `stack` holds the brackets open, innermost first: an
  # object `{:object, keys, state}`, `:paren`, `:bracket`, or `:template`
  # for a `${` inside a template.

  defp scan(<<>>, _prev, _stack, found), do: Enum.reverse(found)

  defp scan(<<c, rest::binary>>, prev, stack, found) when c in ~c" \t\n\r\f\v",
    do: scan(rest, prev, stack, found)

  defp scan(<<"//", rest::binary>>, prev, stack, found),
    do: rest |> after_match(["\n", "\r"]) |> scan(prev, stack, found)

  defp scan(<<"/*", rest::binary>>, prev, stack, found),
    do: rest |> after_match(["*/"]) |> scan(prev, stack, found)

  defp scan(<<?/, rest::binary>>, :start, stack, found),
    do: rest |> regex(false) |> scan(:value, step(stack, :code), found)

  defp scan(<<quote, rest::binary>>, _prev, stack, found) when quote in [?", ?'] do
    {text, rest} = string(rest, quote, [])
    scan(rest, :value, step(stack, {:text, text}), found)
  end

  defp scan(<<?`, rest::binary>>, _prev, stack, found), do: template(rest, [], true, stack, found)

  defp scan(<<c, _::binary>>, _prev, stack, found)
       when c in [?{, ?(, ?[] and length(stack) >= @deepest,
       do: Enum.reverse(found)

  defp scan(<<c, rest::binary>>, _prev, stack, found) when c in [?{, ?(, ?[],
    do: scan(rest, :start, open(stack, c), found)

  defp scan(<<c, rest::binary>>, _prev, stack, found) when c in [?}, ?), ?]] do
    case close(stack, c, found) do
      {:template, stack, found} -> template(rest, [], false, stack, found)
      {stack, found} -> scan(rest, if(c == ?}, do: :start, else: :value), stack, found)
    end
  end

  defp scan(<<c, _::binary>> = code, _prev, stack, found) when c in ?0..?9 do
    {_number, rest} = word(code)
    scan(rest, :value, step(stack, :code), found)
  end

  defp scan(<<c, _::binary>> = code, _prev, stack, found) when word?(c) do
    {word, rest} = word(code)
    prev = if word in @value_starts, do: :start, else: :value
    scan(rest, prev, step(stack, {:word, word}), found)
  end

  defp scan(<<c, rest::binary>>, _prev, stack, found),
    do: scan(rest, :start, step(stack, {:mark, c}), found)

  # The word `code` starts with, and what follows it.
  defp word(code), do: :erlang.split_binary(code, word_size(code, 0))

  defp word_size(<<c, rest::binary>>, size) when word?(c), do: word_size(rest, size + 1)
  defp word_size(_rest, size), do: size

  # What follows the first of `marks`, or nothing when none comes.
  defp after_match(code, marks) do
    case :binary.match(code, marks) do
      {at, length} -> binary_part(code, at + length, byte_size(code) - at - length)
      :nomatch -> <<>>
    end
  end

  # What follows a regular expression's closing `/` and flags; a `/` inside
  # a class such as `[/]` does not close it, and neither does an escaped one.
  defp regex(<<?\\, _escaped, rest::binary>>, class?), do: regex(rest, class?)
  defp regex(<<?[, rest::binary>>, _class?), do: regex(rest, true)
  defp regex(<<?], rest::binary>>, true), do: regex(rest, false)

  defp regex(<<?/, rest::binary>>, false) do
    {_flags, rest} = word(rest)
    rest
  end

  defp regex(<<c, _::binary>> = rest, _class?) when c in [?\n, ?\r], do: rest
  defp regex(<<_c, rest::binary>>, class?), do: regex(rest, class?)
  defp regex(<<>>, _class?), do: <<>>

  ## Strings and templates

  defp string(code, quote, text) do
    case :binary.match(code, [<<quote>>, "\\", "\n", "\r"]) do
      {at, 1} ->
        <<plain::binary-size(^at), mark, rest::binary>> = code

        case mark do
          ?\\ ->
            {character, rest} = escape(rest)
            string(rest, quote, [text, plain, character])

          # The closing quote, or a line break ending a string never closed.
          _end ->
            {IO.iodata_to_binary([text, plain]), rest}
        end

      :nomatch ->
        {IO.iodata_to_binary([text, code]), <<>>}
    end
  end

  # A template's text up to its closing backtick, or up to a `${`, which is
  # read as code until its `}` (`close/3`); the rest of the template's text
  # is read after it. A template is a value's text only when `whole?`, with
  # nothing put into it.
  defp template(code, text, whole?, stack, found) do
    case :binary.match(code, ["`", "\\", "${", "\r"]) do
      {at, length} ->
        <<plain::binary-size(^at), mark::binary-size(^length), rest::binary>> = code
        template_mark(mark, rest, [text, plain], whole?, stack, found)

      :nomatch ->
        Enum.reverse(found)
    end
  end

  defp template_mark("`", rest, text, whole?, stack, found) do
    token = if whole?, do: {:text, IO.iodata_to_binary(text)}, else: :code
    scan(rest, :value, step(stack, token), found)
  end

  defp template_mark("${", _rest, _text, _whole?, stack, found) when length(stack) >= @deepest,
    do: Enum.reverse(found)

  defp template_mark("${", rest, _text, _whole?, stack, found),
    do: scan(rest, :start, open(stack, :template), found)

  defp template_mark("\\", rest, text, whole?, stack, found) do
    {character, rest} = escape(rest)
    template(rest, [text, character], whole?, stack, found)
  end

  # A template reads every line break as "\n".
  defp template_mark("\r", rest, text, whole?, stack, found),
    do: template(after_line_feed(rest), [text, ?\n], whole?, stack, found)

  defp after_line_feed(<<?\n, rest::binary>>), do: rest
  defp after_line_feed(rest), do: rest

  # The character an escape writes, and what follows the escape. A line break
  # after the backslash carries the text on to the next line and writes
  # nothing.
  defp escape(<<"\r\n", rest::binary>>), do: {"", rest}
  defp escape(<<c, rest::binary>>) when c in [?\n, ?\r], do: {"", rest}
  defp escape(<<0xE2, 0x80, c, rest::binary>>) when c in [0xA8, 0xA9], do: {"", rest}
  defp escape(<<?n, rest::binary>>), do: {"\n", rest}
  defp escape(<<?r, rest::binary>>), do: {"\r", rest}
  defp escape(<<?t, rest::binary>>), do: {"\t", rest}
  defp escape(<<?b, rest::binary>>), do: {"\b", rest}
  defp escape(<<?f, rest::binary>>), do: {"\f", rest}
  defp escape(<<?v, rest::binary>>), do: {"\v", rest}
  defp escape(<<?0, rest::binary>>), do: {<<0>>, rest}

  defp escape(<<?x, digits::binary-size(2), rest::binary>> = code) do
    case hex(digits) do
      {:ok, point} -> {<<point::utf8>>, rest}
      :error -> plain(code)
    end
  end

  defp escape(<<"u{", rest::binary>> = code) do
    with {at, 1} <- :binary.match(rest, "}", scope: {0, min(byte_size(rest), @longest_point)}),
         digits = binary_part(rest, 0, at),
         {:ok, point} when point <= 0x10FFFF <- hex(digits) do
      {character(point, "\\u{" <> digits <> "}"),
       binary_part(rest, at + 1, byte_size(rest) - at - 1)}
    else
      _not_a_code_point -> plain(code)
    end
  end

  # Two `\u` halves of one character are that character; a half alone is
  # not a character, and is kept as it is written.
  defp escape(<<?u, high::binary-size(4), "\\u", low::binary-size(4), rest::binary>> = code) do
    with {:ok, high} when high in 0xD800..0xDBFF <- hex(high),
         {:ok, low} when low in 0xDC00..0xDFFF <- hex(low) do
      {<<0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)::utf8>>, rest}
    else
      _not_a_pair -> unit(code)
    end
  end

  defp escape(<<?u, _::binary>> = code), do: unit(code)
  defp escape(code), do: plain(code)

  defp unit(<<?u, digits::binary-size(4), rest::binary>> = code) do
    case hex(digits) do
      {:ok, point} -> {character(point, "\\u" <> digits), rest}
      :error -> plain(code)
    end
  end

  defp unit(code), do: plain(code)

  # Hex digits alone: `Integer.parse/2` would also take a sign.
  defp hex(<<sign, _::binary>>) when sign in [?+, ?-], do: :error

  defp hex(digits) do
    case Integer.parse(digits, 16) do
      {point, ""} -> {:ok, point}
      _not_hex -> :error
    end
  end

  defp character(point, written) when point in 0xD800..0xDFFF, do: written
  defp character(point, _written), do: <<point::utf8>>

  # Any other escaped character stands for itself.
  defp plain(<<c, rest::binary>>), do: {<<c>>, rest}
  defp plain(<<>>), do: {"", <<>>}

  ## Brackets

  defp open([{:object, keys, {:key, key}} | outer], ?(),
    do: [:paren, {:object, Map.put(keys, key, :code), :skip} | outer]

  defp open([{:object, keys, state} | outer], opened),
    do: [frame(opened), {:object, keys, inside(state)} | outer]

  defp open(stack, opened), do: [frame(opened) | stack]

  defp frame(?{), do: {:object, %{}, :key}
  defp frame(?(), do: :paren
  defp frame(?[), do: :bracket
  defp frame(:template), do: :template

  # A bracket opened in a value makes it code; one opened where a key could
  # be, such as `[name]: …`, makes that entry one that is not kept.
  defp inside({:value, key, _value}), do: {:value, key, :code}
  defp inside(_state), do: :skip

  # A closing bracket closes the innermost bracket of its kind and those
  # opened inside it and never closed; one with nothing to close is passed
  # over. An object closed by its own `}` is listed.
  defp close(stack, closer, found) do
    if Enum.any?(stack, &closes?(closer, &1)), do: pop(stack, closer, found), else: {stack, found}
  end

  defp pop([frame | outer], closer, found) do
    cond do
      not closes?(closer, frame) -> pop(outer, closer, found)
      frame == :template -> {:template, outer, found}
      true -> {outer, listed(frame, found)}
    end
  end

  defp closes?(?}, {:object, _keys, _state}), do: true
  defp closes?(?}, :template), do: true
  defp closes?(?), :paren), do: true
  defp closes?(?], :bracket), do: true
  defp closes?(_closer, _frame), do: false

  defp listed({:object, keys, state}, found) do
    case settled(keys, state) do
      keys when map_size(keys) == 0 -> found
      keys -> [keys | found]
    end
  end

  defp listed(_frame, found), do: found

  defp settled(keys, {:value, key, value}), do: Map.put(keys, key, written(value))
  defp settled(keys, {:key, key}), do: Map.put(keys, key, :code)
  defp settled(keys, _state), do: keys

  ## An object's own keys
  #
  # An object reads its own tokens: `:key` where a key may come, `{:key,
  # name}` once one is named, `{:value, name, value}` after its `:`, and
  # `:skip` for an entry that is not kept, up to the next comma. A value is
  # `{:text, parts, :operand}` while text may come next, `{:text, parts,
  # :joined}` after text, and `:code` once it is anything else.

  defp step([{:object, keys, state} | outer], token), do: [entry(keys, state, token) | outer]
  defp step(stack, _token), do: stack

  defp entry(keys, :key, token), do: {:object, keys, key(token)}

  defp entry(keys, {:key, key}, {:mark, ?:}),
    do: {:object, keys, {:value, key, {:text, [], :operand}}}

  defp entry(keys, {:key, key}, {:mark, ?,}), do: {:object, Map.put(keys, key, :code), :key}
  # A word before the key, such as `async` or `get`, is not the key.
  defp entry(keys, {:key, _modifier}, token), do: {:object, keys, key(token)}

  defp entry(keys, {:value, key, value}, {:mark, ?,}),
    do: {:object, Map.put(keys, key, written(value)), :key}

  defp entry(keys, {:value, key, value}, token),
    do: {:object, keys, {:value, key, joined(value, token)}}

  defp entry(keys, :skip, {:mark, ?,}), do: {:object, keys, :key}
  defp entry(keys, :skip, _token), do: {:object, keys, :skip}

  defp key({:word, name}), do: {:key, name}
  defp key({:text, name}), do: {:key, name}
  defp key({:mark, c}) when c in [?*, ?,], do: :key
  defp key(_not_a_key), do: :skip

  defp joined({:text, parts, :operand}, {:text, text}), do: {:text, [parts, text], :joined}
  defp joined({:text, parts, :joined}, {:mark, ?+}), do: {:text, parts, :operand}
  defp joined(_value, _token), do: :code

  defp written({:text, parts, :joined}), do: {:text, IO.iodata_to_binary(parts)}
  defp written(_value), do: :code
end
