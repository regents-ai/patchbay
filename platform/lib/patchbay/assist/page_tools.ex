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
  seen, and none of them can be called from here. The call that signs tools
  up may be in one script and the tools in another it imports, at any depth.

  The code is read as JavaScript (`Patchbay.Assist.ObjectLiterals`), so a
  tool's description is the one written on the tool object itself, read
  whole and as the browser would read it, never one of its parameters'. A
  description put together at run time is not seen, and the tool is kept
  with none. A form's attributes are read as the browser reads them, so a
  description written `Q&amp;A` is kept as `Q&A`. A description longer than
  is kept is cut between words and ends with "…".

  `Patchbay.Forum.ToolName` alone decides what a tool name is: the reader
  picks out every candidate and keeps only the names the board would store.

  Everything is fetched the way an assist reaches a site, through
  `Patchbay.Assist.Target`: public addresses only, nothing but a GET, no
  cookies, and every answer bounded.
  """

  alias Patchbay.Assist.ObjectLiterals
  alias Patchbay.Assist.Target
  alias Patchbay.BoundedText
  alias Patchbay.Forum.Origin
  alias Patchbay.Forum.ToolName

  @max_page_bytes 2 * 1024 * 1024
  @max_script_bytes 2 * 1024 * 1024
  @max_scripts 40
  @max_redirects 3
  @max_tools 200
  @max_description_chars 1_000
  @concurrency 6
  @fetch_timeout_ms 12_000

  @type page :: %{url: String.t(), html: binary(), cut?: boolean()}

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
    with {:ok, page} <- page(site_url, opts), do: {:ok, inspect_tools(page, opts).tools}
  end

  @doc """
  The page at `site_url` after at most a few redirects, each one checked
  again as a new address: the address it was read at, its HTML, and whether
  the HTML was cut at the page bound.
  """
  @spec page(String.t(), keyword()) ::
          {:ok, page()} | {:error, :unresolvable | :not_public | :unreachable}
  def page(site_url, opts \\ []) do
    case Target.get(site_url, page_options(opts, @max_page_bytes, @max_redirects)) do
      {:ok, %{status: 200, url: url, body: html, cut?: cut?}} ->
        {:ok, %{url: url, html: html, cut?: cut?}}

      {:ok, _not_a_page} ->
        {:error, :unreachable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The tools a page already read signs up in its code, in the scripts it
  loads and in the modules those import, and whether the read was complete:
  the page and every script it loads or imports from its own site, at any
  depth, read in full, each answering 200 within the time, size and count
  bounds, and no more tools than are kept. A tool missing from an incomplete
  read may still be on the page.
  """
  @spec inspect_tools(page(), keyword()) :: %{tools: [tool()], complete?: boolean()}
  def inspect_tools(%{url: page_url, html: html, cut?: cut?}, opts \\ []) do
    host = URI.parse(page_url).host
    page = {page_url, html}
    wanted = Enum.uniq(own_site(script_urls(html, page_url), host) ++ imported_urls([page], host))
    {scripts, scripts_complete?} = read_scripts(wanted, [], [], true, host, opts)
    read = [page | scripts]

    # The call that signs tools up and the tools it is handed are often in
    # different scripts, so the page as a whole is asked whether it signs any up.
    code = inline_scripts(html) ++ Enum.map(scripts, fn {_url, code} -> code end)

    tools =
      if Enum.any?(read, fn {_url, code} -> code =~ ~r/registerTool|provideContext/ end),
        do: Enum.flat_map(code, &script_tools/1),
        else: []

    tools = Enum.uniq_by(form_tools(html) ++ tools, & &1.name)

    %{
      tools: Enum.take(tools, @max_tools),
      complete?: not cut? and scripts_complete? and length(tools) <= @max_tools
    }
  end

  # Reads `wanted` and then, round by round, the own-site modules those
  # import, until a round names nothing new or the script count is reached.
  # Complete when every script named was read in full.
  defp read_scripts(wanted, asked, read, complete?, host, opts) do
    new = wanted -- asked

    case Enum.take(new, @max_scripts - length(asked)) do
      [] ->
        {read, complete? and new == []}

      round ->
        {fetched, whole?} = fetch_all(round, opts)

        read_scripts(
          imported_urls(fetched, host),
          asked ++ round,
          read ++ fetched,
          complete? and whole? and length(round) == length(new),
          host,
          opts
        )
    end
  end

  defp imported_urls(scripts, host) do
    scripts
    |> Enum.flat_map(fn {url, code} -> imports(code, url) end)
    |> own_site(host)
    |> Enum.uniq()
  end

  defp page_options(opts, bound, redirects) do
    Keyword.merge(opts,
      max_body_bytes: bound,
      redirects: redirects,
      receive_timeout: @fetch_timeout_ms
    )
  end

  defp fetch_all(urls, opts) do
    urls
    |> Task.async_stream(&script(&1, opts),
      max_concurrency: @concurrency,
      timeout: @fetch_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.reduce({[], true}, fn
      {:ok, {:ok, fetched, whole?}}, {found, complete?} ->
        {[fetched | found], complete? and whole?}

      _unread, {found, _complete?} ->
        {found, false}
    end)
    |> then(fn {found, complete?} -> {Enum.reverse(found), complete?} end)
  end

  defp script(url, opts) do
    case Target.get(url, page_options(opts, @max_script_bytes, 0)) do
      # A script cut at the bound is still searched, but the read is not complete.
      {:ok, %{status: 200, body: body, cut?: cut?}} -> {:ok, {url, body}, not cut?}
      _unread -> :unread
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

  # Scripts from the page's own site: the same name, or another name under
  # the same registrable domain, like static.example.co.uk for
  # www.example.co.uk. Two shared-host names such as a.vercel.app and
  # b.vercel.app are different sites.
  defp own_site(urls, host) do
    site = Origin.normalize(host)

    Enum.filter(urls, fn url ->
      case URI.parse(url) do
        %URI{scheme: "https", host: ^host} -> true
        %URI{scheme: "https", host: other} when is_binary(other) -> same_site?(other, site)
        _elsewhere -> false
      end
    end)
  end

  defp same_site?(other, {:ok, site}), do: Origin.normalize(other) == {:ok, site}
  defp same_site?(_other, {:error, _not_a_site}), do: false

  # Forms the page marks as tools, by the attributes WebMCP reads, read as
  # the browser reads them: the first of each name counts, and character
  # references such as `&amp;` are decoded once.
  defp form_tools(html) do
    for [tag] <- Regex.scan(~r/<form\b[^>]*>/i, html),
        {:ok, [{"form", attributes, _children}]} <- [Floki.parse_fragment(tag)],
        name = form_attribute(attributes, "toolname"),
        ToolName.valid?(name),
        do: tool(name, form_attribute(attributes, "tooldescription") || "")
  end

  defp form_attribute(attributes, name),
    do: attributes |> List.keyfind(name, 0, {name, nil}) |> elem(1)

  # Tool objects in a page's code: an object whose own keys name the tool in
  # text and hold an input schema or the function run. Its description is
  # the one written on that object, never one written inside it, such as a
  # parameter's; a tool whose description is not written as text, or not
  # written at all, is kept with none.
  defp script_tools(code) do
    for keys <- ObjectLiterals.read(code),
        {:text, name} <- [keys["name"]],
        ToolName.valid?(name),
        Enum.any?(~w(inputSchema input_schema execute), &Map.has_key?(keys, &1)) do
      tool(name, own_description(keys["description"]))
    end
  end

  defp own_description({:text, description}), do: description
  defp own_description(_not_written_as_text), do: ""

  # The code inside a page's own `<script>` elements.
  defp inline_scripts(html) do
    for [code] <- Regex.scan(~r/<script\b[^>]*>(.*?)<\/script/is, html, capture: :all_but_first),
        do: code
  end

  defp tool(name, description) do
    %{
      name: name,
      description:
        description
        |> String.replace_invalid("")
        |> String.trim()
        |> BoundedText.cut(@max_description_chars),
      input_schema: nil,
      read_only?: false
    }
  end

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
