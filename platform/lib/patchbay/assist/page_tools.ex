defmodule Patchbay.Assist.PageTools do
  @moduledoc """
  The WebMCP tools a site's page signs up in its own code, found by reading
  that code rather than running it.

  A WebMCP tool exists only once a browser runs the page: a script hands
  `navigator.modelContext` an object with the tool's name, description and
  input schema, or a form carries a `toolname`. Patchbay reads the page, the
  scripts it loads from its own site and the scripts those import, and
  picks those out. It finds the tools a page writes into its code; a tool
  put together at run time, or loaded from another company's site, is not
  seen, and none of them can be called from here.

  Everything is fetched the way an assist reaches a site, through
  `Patchbay.Assist.Target`: public addresses only, nothing but a GET, no
  cookies, and every answer bounded.
  """

  alias Patchbay.Assist.Target

  @max_page_bytes 2 * 1024 * 1024
  @max_script_bytes 2 * 1024 * 1024
  @max_scripts 40
  @max_redirects 3
  @max_tools 100
  @max_description_chars 1_000
  @concurrency 6
  @fetch_timeout_ms 12_000
  # How far past a tool's name its description and schema are looked for.
  @tool_window_bytes 2_000

  @tool_name ~r/["']?name["']?\s*:\s*["'`]([A-Za-z_][\w.\-]{0,63})["'`]/
  @takes_input ~r/["']?(inputSchema|input_schema|execute)["']?\s*[:(]/
  # A description in double, single or back quotes.
  @description ~r/["']?description["']?\s*:\s*(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|`([^`]*)`)/s

  @type tool :: %{
          name: String.t(),
          description: String.t(),
          input_schema: nil,
          read_only?: false
        }

  @doc """
  The tools the page at `site_url` signs up in its code, or why the page
  could not be read. `opts` are `Target.connect/2`'s.
  """
  @spec read(String.t(), keyword()) ::
          {:ok, [tool()]} | {:error, :unresolvable | :not_public | :unreachable}
  def read(site_url, opts \\ []) do
    with {:ok, page_url, html} <- page(site_url, opts, @max_redirects) do
      host = URI.parse(page_url).host
      loaded = html |> script_urls(page_url) |> own_site(host) |> Enum.take(@max_scripts)
      first = fetch_all(loaded, opts)

      imported =
        first
        |> Enum.flat_map(fn {url, code} -> imports(code, url) end)
        |> own_site(host)
        |> Kernel.--(loaded)
        |> Enum.take(@max_scripts - length(loaded))

      codes = [html | Enum.map(first ++ fetch_all(imported, opts), &elem(&1, 1))]

      tools =
        (form_tools(html) ++ Enum.flat_map(codes, &script_tools/1))
        |> Enum.uniq_by(& &1.name)
        |> Enum.take(@max_tools)

      {:ok, tools}
    end
  end

  # The page itself, after at most a few redirects, each one checked again
  # as a new address.
  defp page(_url, _opts, -1), do: {:error, :unreachable}

  defp page(url, opts, redirects_left) do
    case get(url, opts, @max_page_bytes) do
      {:ok, 200, body, _location} ->
        {:ok, url, body}

      {:ok, status, _body, location} when status in 301..308 and is_binary(location) ->
        page(url |> URI.merge(location) |> URI.to_string(), opts, redirects_left - 1)

      {:ok, _status, _body, _location} ->
        {:error, :unreachable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_all(urls, opts) do
    urls
    |> Task.async_stream(&script(&1, opts),
      max_concurrency: @concurrency,
      timeout: @fetch_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {:ok, fetched}} -> [fetched]
      _unread -> []
    end)
  end

  defp script(url, opts) do
    case get(url, opts, @max_script_bytes) do
      {:ok, 200, body, _location} -> {:ok, {url, body}}
      _unread -> :unread
    end
  end

  defp get(url, opts, bound) do
    with {:ok, target} <- Target.connect(url, Keyword.put(opts, :max_body_bytes, bound)),
         {:ok, %Req.Response{} = response} <-
           Req.get(
             target.url,
             [compressed: false, receive_timeout: @fetch_timeout_ms] ++ target.options
           ) do
      body = response.body |> Kernel.||("") |> IO.iodata_to_binary()
      {:ok, response.status, body, Req.Response.get_header(response, "location") |> List.first()}
    else
      {:error, reason} when reason in [:unresolvable, :not_public] -> {:error, reason}
      _failed -> {:error, :unreachable}
    end
  end

  # Every script the page loads by address, and every module it asks the
  # browser to fetch ahead.
  defp script_urls(html, page_url) do
    scripts =
      for [tag] <- Regex.scan(~r/<script\b[^>]*>/i, html),
          src = attribute(tag, "src"),
          do: src

    preloads =
      for [tag] <- Regex.scan(~r/<link\b[^>]*>/i, html),
          (attribute(tag, "rel") || "") =~ ~r/modulepreload/i,
          href = attribute(tag, "href"),
          do: href

    (scripts ++ preloads) |> Enum.map(&absolute(&1, page_url)) |> Enum.uniq()
  end

  # The modules a script imports by address, as the browser would find them.
  defp imports(code, script_url) do
    ~r/(?:\bfrom\s*|\bimport\s*\(?\s*)["']([^"'\s]+\.m?js(?:\?[^"'\s]*)?)["']/
    |> Regex.scan(code, capture: :all_but_first)
    |> Enum.map(fn [path] -> absolute(path, script_url) end)
    |> Enum.uniq()
  end

  defp absolute(path, base), do: base |> URI.merge(path) |> URI.to_string()

  # Scripts from the page's own site: the same name, or a name under the
  # same parent, like static.example.com for www.example.com.
  defp own_site(urls, host) do
    parent = parent(host)

    Enum.filter(urls, fn url ->
      case URI.parse(url) do
        %URI{scheme: "https", host: ^host} -> true
        %URI{scheme: "https", host: other} when is_binary(other) -> parent(other) == parent
        _elsewhere -> false
      end
    end)
  end

  defp parent(host), do: host |> String.split(".") |> Enum.take(-2) |> Enum.join(".")

  # Forms the page marks as tools, by the attributes WebMCP reads.
  defp form_tools(html) do
    for [tag] <- Regex.scan(~r/<form\b[^>]*>/i, html),
        name = attribute(tag, "toolname"),
        tool_name?(name),
        do: tool(name, attribute(tag, "tooldescription") || "")
  end

  # Tool objects in code that signs tools up: a name, then within the same
  # object a description and either an input schema or the function run.
  defp script_tools(code) do
    if code =~ ~r/registerTool|provideContext/ do
      starts = Regex.scan(@tool_name, code, return: :index)

      starts
      |> Enum.with_index()
      |> Enum.flat_map(fn {[{at, _length}, {name_at, name_length}], index} ->
        window = window(code, at, Enum.at(starts, index + 1))
        tool_object(binary_part(code, name_at, name_length), window)
      end)
    else
      []
    end
  end

  defp window(code, at, next) do
    stop =
      case next do
        [{next_at, _length} | _rest] -> next_at
        nil -> byte_size(code)
      end

    binary_part(code, at, min(stop - at, @tool_window_bytes))
  end

  defp tool_object(name, window) do
    with true <- window =~ @takes_input,
         [_ | _] = texts <- Regex.run(@description, window, capture: :all_but_first) do
      [tool(name, first_written(texts))]
    else
      _not_a_tool -> []
    end
  end

  defp tool(name, description) do
    %{
      name: name,
      description: description |> unescape() |> String.slice(0, @max_description_chars),
      input_schema: nil,
      read_only?: false
    }
  end

  defp tool_name?(name), do: is_binary(name) and name =~ ~r/\A[A-Za-z_][\w.\-]{0,63}\z/

  defp unescape(text) do
    ~r/\\u([0-9a-fA-F]{4})/
    |> Regex.replace(text, fn escape, code -> character(String.to_integer(code, 16), escape) end)
    |> String.replace(~S(\n), " ")
    |> String.replace(~S(\"), ~S("))
    |> String.replace(~S(\'), "'")
    |> String.trim()
  end

  # Half of a pair that spells one character is not a character alone.
  defp character(code, escape) when code in 0xD800..0xDFFF, do: escape
  defp character(code, _escape), do: <<code::utf8>>

  defp attribute(tag, name) do
    case Regex.run(~r/\s#{name}\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/i, tag,
           capture: :all_but_first
         ) do
      nil -> nil
      texts -> first_written(texts)
    end
  end

  # Of a pattern's quoted alternatives, the one that matched.
  defp first_written(texts), do: Enum.find(texts, "", &(&1 != ""))
end
