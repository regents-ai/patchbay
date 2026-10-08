defmodule Patchbay.Forum.SiteScan do
  @moduledoc """
  Finds what a site offers agents, from what it publishes and what is listed
  about it elsewhere:

  - its front page: the WebMCP tools its code signs up, and its links to
    GitHub, npm and PyPI;
  - its MCP servers: the ones its server card (`/.well-known/mcp.json` or
    `/.well-known/mcp`) names, the one at `/mcp`, and the ones the official
    MCP Registry lists under its name. Each is asked for its tools; one that
    asks for a sign-in first is noted as such;
  - the files agents read: `/llms.txt`, `/.well-known/api-catalog`,
    `/openapi.json`, `/.well-known/skills/index.json`, `/skill.md` and
    `/.well-known/agent-card.json`, each counted only when it is what its
    name says;
  - the official MCP Registry's entries under the site's reversed name
    (`com.example/…`), which the registry lets only the domain's owner
    publish, and GitHub repositories and npm packages named like the site.
    A repository or package whose homepage is on the site is from the site;
    at most three of the others are kept as maybe related.

  The site's own addresses are read through `Patchbay.Assist.Target`: public
  addresses only, nothing but a GET (and MCP's own POSTs to a server), no
  cookies, every answer bounded. Everything found is a stranger's text,
  kept short and only ever shown.

  The answer is a map with string keys, as it is stored: `"page_url"` (the
  front page that was read, or nil), `"webmcp"`, `"servers"`, `"files"`,
  `"code"` and `"unsearched"` (the outside lists that could not be searched
  just now).
  """

  alias Patchbay.Assist.McpClient
  alias Patchbay.Assist.PageTools
  alias Patchbay.Assist.Target
  alias Patchbay.Forum.Origin

  @file_bytes 256 * 1024
  @redirects 3
  @read_timeout_ms 12_000
  @search_timeout_ms 40_000
  @all_timeout_ms 45_000
  @most_servers 4
  @most_tools 100
  @most_links 10
  @most_related 3
  @most_from_site 5
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

  # github.com paths that are GitHub's own pages, not an account.
  @github_pages ~w(about apps collections contact customer-stories enterprise events explore
                   features login marketplace new notifications orgs pricing pulls search
                   security settings site sponsors team topics trending)

  @registry "https://registry.modelcontextprotocol.io/v0/servers"
  @github "https://api.github.com/search/repositories"
  @npm "https://registry.npmjs.org/-/v1/search"

  @type findings :: %{String.t() => term()}

  @doc """
  What `domain`, a registrable domain, offers agents. `opts` are
  `Patchbay.Assist.Target.connect/2`'s, for the site's own addresses.
  """
  @spec findings(String.t(), keyword()) :: findings()
  def findings(domain, opts) do
    site = "https://" <> domain
    label = label(domain)

    found =
      [
        page: fn -> front_page(site, opts) end,
        cards: fn -> cards(site, opts) end,
        files: fn -> files(site, opts) end,
        registry: fn -> registry(domain) end,
        github: fn -> github(label, domain) end,
        npm: fn -> npm(label, domain) end
      ]
      |> Task.async_stream(fn {part, read} -> {part, read.()} end,
        timeout: @all_timeout_ms,
        on_timeout: :kill_task,
        max_concurrency: 6,
        ordered: true
      )
      |> Enum.zip([:page, :cards, :files, :registry, :github, :npm])
      |> Map.new(fn
        {{:ok, {part, answer}}, part} -> {part, answer}
        {{:exit, :timeout}, part} -> {part, timed_out(part)}
      end)

    {page_url, webmcp, links} = found.page

    %{
      "page_url" => page_url,
      "webmcp" => webmcp,
      "servers" => servers(found.cards, found.registry, site, domain, opts),
      "files" => found.files,
      "code" => links ++ listed(found.registry) ++ listed(found.github) ++ listed(found.npm),
      "unsearched" =>
        for(
          {source, :busy} <- [registry: found.registry, github: found.github, npm: found.npm],
          do: Atom.to_string(source)
        )
    }
  end

  defp timed_out(:page), do: {nil, [], []}
  defp timed_out(part) when part in [:cards, :files], do: []
  defp timed_out(_search), do: :busy

  # The name a company is searched by: the domain without its ending.
  defp label(domain) do
    case Domainatrex.parse(domain) do
      {:ok, %{domain: label}} -> label
      {:error, _not_a_domain} -> domain
    end
  end

  ## The front page

  defp front_page(site, opts) do
    case PageTools.page(site <> "/", opts) do
      {:ok, page_url, html} ->
        tools =
          page_url
          |> PageTools.tools(html, opts)
          |> Enum.map(&%{"name" => &1.name, "description" => &1.description})

        {page_url, tools, links(html, page_url)}

      {:error, _unread} ->
        {nil, [], []}
    end
  end

  # The site's own links to its code and packages.
  defp links(html, page_url) do
    ~r/<a\b[^>]*\bhref\s*=\s*["']([^"']+)["']/i
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.flat_map(fn [href] -> href |> absolute(page_url) |> code_link() end)
    |> Enum.uniq_by(& &1["url"])
    |> Enum.take(@most_links)
  end

  defp absolute(href, base) do
    base |> URI.merge(href) |> URI.to_string()
  rescue
    _not_an_address -> ""
  end

  defp code_link(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, path: path}
      when host in ["github.com", "www.github.com"] ->
        github_link(String.split(path || "", "/", trim: true))

      %URI{scheme: "https", host: host, path: "/package/" <> name}
      when host in ["npmjs.com", "www.npmjs.com"] ->
        package_link("npm", "https://www.npmjs.com/package/", name)

      %URI{scheme: "https", host: "pypi.org", path: "/project/" <> name} ->
        package_link("pypi", "https://pypi.org/project/", name)

      _elsewhere ->
        []
    end
  end

  defp github_link([owner | rest]) when owner not in @github_pages do
    name = Enum.join([owner | Enum.take(rest, 1)], "/")

    if name =~ ~r/\A[\w.-]+(\/[\w.-]+)?\z/,
      do: [code("github", name, "https://github.com/" <> name, nil, true)],
      else: []
  end

  defp github_link(_github_own_page), do: []

  defp package_link(source, base, path) do
    name = path |> String.trim_trailing("/") |> URI.decode()

    if name =~ ~r/\A(@[\w.-]+\/)?[\w.-]+\z/,
      do: [code(source, name, base <> name, nil, true)],
      else: []
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
    listed =
      for %{"remotes" => remotes} <- registered(registry),
          url <- remotes,
          on_site?(url, domain),
          do: %{"url" => url}

    (cards ++ [%{"url" => site <> "/mcp", "guessed" => true}] ++ listed)
    |> Enum.uniq_by(& &1["url"])
    |> Enum.take(@most_servers)
    |> Task.async_stream(&server(&1, opts),
      timeout: @all_timeout_ms,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.flat_map(fn
      {:ok, [_server] = found} -> found
      _not_a_server -> []
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
    |> Task.async_stream(fn {kind, path, form} -> agent_file(kind, site <> path, form, opts) end,
      timeout: @all_timeout_ms,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.flat_map(fn
      {:ok, [_file] = found} -> found
      _unread -> []
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

  ## Lists elsewhere

  defp registry(domain) do
    namespace = domain |> String.split(".") |> Enum.reverse() |> Enum.join(".")

    with {:ok, %{"servers" => servers}} when is_list(servers) <-
           search(@registry, search: namespace, limit: 20) do
      found =
        for %{"server" => %{"name" => name} = server} = entry <- servers,
            is_binary(name),
            String.starts_with?(name, namespace <> "/") or
              String.starts_with?(name, namespace <> "."),
            latest?(entry) do
          %{
            "name" => short(name, @name_chars),
            "description" => short(server["description"]),
            "url" => registry_url(server),
            "remotes" => for(%{"url" => url} <- server["remotes"] || [], https?(url), do: url)
          }
        end

      {:ok, Enum.take(found, @most_from_site)}
    end
  end

  defp latest?(%{"_meta" => %{"io.modelcontextprotocol.registry/official" => meta}}),
    do: meta["isLatest"] != false

  defp latest?(_unmarked), do: true

  defp registry_url(server) do
    Enum.find(
      [get_in(server, ["repository", "url"]), server["websiteUrl"]],
      @registry <> "?search=" <> URI.encode_www_form(server["name"]),
      &https?/1
    )
  end

  defp registered({:ok, entries}), do: entries
  defp registered(:busy), do: []

  defp github(label, domain) do
    with :ok <- searchable(label),
         {:ok, %{"items" => items}} when is_list(items) <-
           search(@github, q: label <> " in:name", sort: "stars", per_page: 20) do
      {:ok,
       ranked(
         for %{"full_name" => name, "html_url" => url} = repo <- items,
             is_binary(name),
             https?(url) do
           code("github", name, url, repo["description"], on_site?(repo["homepage"], domain))
         end
       )}
    end
  end

  defp npm(label, domain) do
    with :ok <- searchable(label),
         {:ok, %{"objects" => objects}} when is_list(objects) <-
           search(@npm, text: label, size: 20) do
      {:ok,
       ranked(
         for %{"package" => %{"name" => name} = package} <- objects, is_binary(name) do
           links = package["links"] || %{}

           code(
             "npm",
             name,
             "https://www.npmjs.com/package/" <> name,
             package["description"],
             on_site?(links["homepage"], domain)
           )
         end
       )}
    end
  end

  # A name of one or two letters matches half of GitHub and npm.
  defp searchable(label) when byte_size(label) >= 3, do: :ok
  defp searchable(_short), do: {:ok, :not_searched}

  defp ranked(found) do
    {from_site, others} = Enum.split_with(found, & &1["from_site"])
    Enum.take(from_site, @most_from_site) ++ Enum.take(others, @most_related)
  end

  defp listed({:ok, entries}) when is_list(entries) do
    Enum.map(entries, fn
      %{"source" => _source} = entry ->
        entry

      registry ->
        code("registry", registry["name"], registry["url"], registry["description"], true)
    end)
  end

  defp listed(_not_listed), do: []

  # An outside list that is down, slow or rate limiting is unsearched, not empty.
  defp search(url, params) do
    options =
      [
        url: url,
        params: params,
        headers: [{"accept", "application/json"}, {"user-agent", "Patchbay (patchbay.help)"}],
        receive_timeout: @search_timeout_ms,
        retry: false
      ] ++ Application.get_env(:patchbay, :site_scan_req_options, [])

    case Req.get(options) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> decoded(body)
      _down_or_limited -> :busy
    end
  end

  defp decoded(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _not_json -> :busy
    end
  end

  ## Shapes

  defp code(source, name, url, description, from_site?) do
    %{
      "source" => source,
      "name" => short(name, @name_chars),
      "url" => url,
      "description" => short(description),
      "from_site" => from_site?
    }
  end

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
end
