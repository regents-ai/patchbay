defmodule Patchbay.Forum.SiteScan do
  @moduledoc """
  Finds what a site offers agents, from what the site itself publishes:

  - its front page: the WebMCP tools its code signs up;
  - its MCP servers: the ones its server card (`/.well-known/mcp.json` or
    `/.well-known/mcp`) names, the one at `/mcp`, and the ones on its own
    domain that the official MCP Registry lists under its reversed name
    (`com.example/…`), which the registry lets only the domain's owner
    publish. Each is asked for its tools; one that asks for a sign-in first
    is noted as such;
  - the files agents read: `/llms.txt`, `/.well-known/api-catalog`,
    `/openapi.json`, `/.well-known/skills/index.json`, `/skill.md` and
    `/.well-known/agent-card.json`, each counted only when it is what its
    name says.

  The site's own addresses are read through `Patchbay.Assist.Target`: public
  addresses only, nothing but a GET (and MCP's own POSTs to a server), no
  cookies, every answer bounded. Everything found is a stranger's text,
  kept short and only ever shown.

  The answer is the front page that was read (or nil), whether that page and
  every script it loads or imports from the site's own domain were read in
  full (`Patchbay.Assist.PageTools.inspect_tools/2`), and what was found: a
  map with string keys, as it is stored, of `"webmcp"`, `"servers"` and
  `"files"`.
  """

  alias Patchbay.Assist.McpClient
  alias Patchbay.Assist.PageTools
  alias Patchbay.Assist.Target
  alias Patchbay.Forum.Origin
  alias Patchbay.Forum.SiteDirectory

  @file_bytes 256 * 1024
  @redirects 3
  @read_timeout_ms 12_000
  @search_timeout_ms 40_000
  @all_timeout_ms 45_000
  @most_servers 4
  @most_tools 100
  @name_chars 128
  @text_chars 500

  @card_paths ["/.well-known/mcp.json", "/.well-known/mcp"]

  @files [
    {"llms_txt", "/llms.txt", :text},
    {"api_catalog", "/.well-known/api-catalog", :json},
    {"openapi", "/openapi.json", :json},
    {"skills", "/.well-known/skills/index.json", :json},
    {"skill_md", "/skill.md", :text},
    {"agent_card", "/.well-known/agent-card.json", :json}
  ]

  @registry "https://registry.modelcontextprotocol.io/v0/servers"

  @type findings :: %{String.t() => term()}

  @doc "The supervisor a check's reads run under, started with the application."
  @spec tasks() :: module()
  def tasks, do: __MODULE__.Tasks

  @doc """
  What `domain`, a registrable domain, offers agents. `opts` are
  `Patchbay.Assist.Target.connect/2`'s, for the site's own addresses.
  """
  @spec findings(String.t(), keyword()) :: {String.t() | nil, boolean(), findings()}
  def findings(domain, opts) do
    site = "https://" <> domain

    found =
      [
        page: fn -> front_page(site, opts) end,
        cards: fn -> cards(site, opts) end,
        files: fn -> files(site, opts) end,
        registry: fn -> registry(domain) end
      ]
      |> each(fn {part, read} -> {part, read.()} end, max_concurrency: 4)
      |> Enum.zip([:page, :cards, :files, :registry])
      |> Map.new(fn
        {{:ok, {part, answer}}, part} -> {part, answer}
        {{:exit, :timeout}, part} -> {part, timed_out(part)}
      end)

    {page_url, complete?, webmcp} = found.page

    {storable(page_url), complete?,
     storable(%{
       "webmcp" => webmcp,
       "servers" => servers(found.cards, found.registry, site, domain, opts),
       "files" => found.files
     })}
  end

  @doc "Read the directory's exact public pages without calling any discovered tool."
  def directory_findings(domain, previous, opts) do
    earlier = (previous || %{})["directory"] || %{}
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    domain
    |> SiteDirectory.pages()
    |> each(
      fn url ->
        snapshot =
          with {:ok, %{url: page_url} = page} <- PageTools.page(url, opts),
               %{complete?: true, tools: tools} <- PageTools.inspect_tools(page, opts) do
            %{
              "checked_at" => now,
              "page_url" => page_url,
              "failed" => false,
              "tools" => Enum.map(tools, &%{"name" => &1.name, "address" => page_url})
            }
          else
            _incomplete ->
              Map.merge(earlier[url] || %{}, %{"failed" => true, "last_attempt_at" => now})
          end

        {url, snapshot}
      end,
      max_concurrency: 3
    )
    |> Enum.zip(SiteDirectory.pages(domain))
    |> Map.new(fn
      {{:ok, {url, snapshot}}, _requested} ->
        {url, snapshot}

      {{:exit, :timeout}, url} ->
        {url, Map.merge(earlier[url] || %{}, %{"failed" => true, "last_attempt_at" => now})}
    end)
    |> storable()
  end

  # Several reads at once, each given `@all_timeout_ms`: `{:ok, answer}` in
  # the order asked, or `{:exit, :timeout}` for one that ran out of time. The
  # reads run unlinked under `tasks/0`, so one that ends any other way, with an
  # error or an exit, is raised here, in the check's own job, which tries the
  # check again and then records it as one that could not be done.
  defp each(asked, read, opts \\ []) do
    tasks()
    |> Task.Supervisor.async_stream_nolink(
      asked,
      read,
      [timeout: @all_timeout_ms, on_timeout: :kill_task, ordered: true] ++ opts
    )
    |> Enum.map(fn
      {:exit, reason} when reason != :timeout ->
        raise "a site read ended early: " <> Exception.format_exit(reason)

      answer ->
        answer
    end)
  end

  defp timed_out(:page), do: {nil, false, []}
  defp timed_out(_part), do: []

  ## The front page

  defp front_page(site, opts) do
    case PageTools.page(site <> "/", opts) do
      {:ok, %{url: page_url} = page} ->
        %{tools: tools, complete?: complete?} = PageTools.inspect_tools(page, opts)
        webmcp = Enum.map(tools, &%{"name" => &1.name, "description" => &1.description})
        {page_url, complete?, webmcp}

      {:error, _unread} ->
        {nil, false, []}
    end
  end

  ## MCP servers

  defp cards(site, opts) do
    @card_paths
    |> Enum.flat_map(&card_servers(json(site <> &1, opts)))
    |> Enum.uniq_by(& &1["url"])
  end

  defp card_servers({:ok, %{"endpoints" => [_ | _] = endpoints} = card, card_url}) do
    for %{"url" => url} <- endpoints, https?(url) do
      %{
        "url" => url,
        "card" => card_url,
        "name" => short(card["name"], @name_chars),
        "description" => short(card["description"]),
        "documentation" => if(https?(card["documentation"]), do: card["documentation"])
      }
    end
  end

  defp card_servers(_no_card), do: []

  # The servers a card names, the one at `/mcp`, and the registry's on the
  # site's domain, each asked for its tools.
  defp servers(cards, registry, site, domain, opts) do
    listed = for url <- registry, on_site?(url, domain), do: %{"url" => url}

    (cards ++ [%{"url" => site <> "/mcp", "guessed" => true}] ++ listed)
    |> Enum.uniq_by(& &1["url"])
    |> Enum.take(@most_servers)
    |> each(&server(&1, opts))
    |> Enum.flat_map(fn
      {:ok, found} -> found
      {:exit, :timeout} -> []
    end)
  end

  defp server(%{"url" => url} = known, opts) do
    answer =
      with {:ok, target} <- Target.connect(url, opts),
           {:ok, client} <- McpClient.open(target) do
        McpClient.list_tools(client)
      end

    shown = Map.take(known, ["url", "card", "name", "description", "documentation"])

    case answer do
      {:ok, tools} ->
        [Map.merge(shown, %{"answered" => true, "sign_in" => false, "tools" => tool_list(tools)})]

      {:error, :needs_sign_in} ->
        [Map.merge(shown, %{"answered" => true, "sign_in" => true, "tools" => []})]

      # A guess at `/mcp` that is not a server is nothing found; a server a
      # card or the registry names that does not answer is still worth naming.
      {:error, _not_answered} when is_map_key(known, "guessed") ->
        []

      {:error, _not_answered} ->
        [Map.merge(shown, %{"answered" => false, "sign_in" => false, "tools" => []})]
    end
  end

  defp tool_list(tools) do
    tools
    |> Enum.take(@most_tools)
    |> Enum.map(&%{"name" => short(&1.name, @name_chars), "description" => short(&1.description)})
  end

  ## Files agents read

  defp files(site, opts) do
    @files
    |> each(fn {kind, path, form} -> agent_file(kind, site <> path, form, opts) end)
    |> Enum.flat_map(fn
      {:ok, found} -> found
      {:exit, :timeout} -> []
    end)
  end

  defp agent_file(kind, url, :json, opts) do
    case json(url, opts) do
      {:ok, %{} = file, read_url} ->
        [%{"kind" => kind, "url" => read_url, "title" => short(get_in(file, ["info", "title"]))}]

      _not_that_file ->
        []
    end
  end

  defp agent_file(kind, url, :text, opts) do
    case read(url, opts) do
      {:ok, %{status: 200, body: body, type: type, url: read_url}} ->
        if text?(body, type), do: [%{"kind" => kind, "url" => read_url, "title" => nil}], else: []

      _unread ->
        []
    end
  end

  defp json(url, opts) do
    with {:ok, %{status: 200, body: body, url: read_url}} <- read(url, opts),
         {:ok, %{} = file} <- Jason.decode(body) do
      {:ok, file, read_url}
    end
  end

  # A site that answers every address with its app's page has no such file.
  defp text?(body, type) do
    String.trim(body) != "" and not String.starts_with?(String.trim_leading(body), "<") and
      not String.contains?(String.downcase(type), "html")
  end

  defp read(url, opts) do
    Target.get(
      url,
      Keyword.merge(opts,
        max_body_bytes: @file_bytes,
        redirects: @redirects,
        receive_timeout: @read_timeout_ms
      )
    )
  end

  ## The MCP Registry

  # The addresses of the servers the official MCP Registry lists under the
  # site's reversed name, at their latest version. A registry that is down,
  # slow or limiting lists none just now.
  defp registry(domain) do
    namespace = domain |> String.split(".") |> Enum.reverse() |> Enum.join(".")

    case search(namespace) do
      {:ok, %{"servers" => servers}} when is_list(servers) ->
        for %{"server" => %{"name" => name} = server} = entry <- servers,
            is_binary(name),
            String.starts_with?(name, namespace <> "/") or
              String.starts_with?(name, namespace <> "."),
            latest?(entry),
            %{"url" => url} <- server["remotes"] || [],
            https?(url),
            do: url

      _unlisted ->
        []
    end
  end

  defp latest?(%{"_meta" => %{"io.modelcontextprotocol.registry/official" => meta}}),
    do: meta["isLatest"] != false

  defp latest?(_unmarked), do: true

  defp search(namespace) do
    options =
      [
        url: @registry,
        params: [search: namespace, limit: 20],
        headers: [{"accept", "application/json"}, {"user-agent", "Patchbay (patchbay.help)"}],
        receive_timeout: @search_timeout_ms,
        retry: false
      ] ++ Application.get_env(:patchbay, :site_scan_req_options, [])

    case Req.get(options) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> Jason.decode(body)
      _down_or_limited -> :unlisted
    end
  end

  ## Shapes

  defp on_site?(url, domain) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["https", "http"] and is_binary(host) ->
        Origin.normalize(host) == {:ok, domain}

      _not_an_address ->
        false
    end
  end

  defp on_site?(_absent, _domain), do: false

  defp https?(url) when is_binary(url) and byte_size(url) <= 2048,
    do: match?(%URI{scheme: "https", host: host} when is_binary(host), URI.parse(url))

  defp https?(_not_an_address), do: false

  defp short(text, chars \\ @text_chars)

  defp short(text, chars) when is_binary(text),
    do: text |> String.trim() |> String.slice(0, chars)

  defp short(_absent, _chars), do: nil

  # What was found, as it can be stored: a stranger's text may hold bytes
  # that are no text and the NUL character, and Postgres keeps neither. Both
  # are dropped here, once, from everything a check hands back.
  defp storable(%{} = found), do: Map.new(found, fn {key, value} -> {key, storable(value)} end)
  defp storable(found) when is_list(found), do: Enum.map(found, &storable/1)

  defp storable(text) when is_binary(text),
    do: text |> String.replace_invalid("") |> String.replace(<<0>>, "")

  defp storable(other), do: other
end
