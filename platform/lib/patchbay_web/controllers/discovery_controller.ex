defmodule PatchbayWeb.DiscoveryController do
  @moduledoc """
  The files an agent or crawler reads to find its way around: the API
  description, the agent guide, robots.txt, the security contact, the API
  catalog and `/capabilities.json`, which names the build this release runs
  the regents-cli release its guides install and, for every operation, who
  may run it and how an agent reaches it (`Patchbay.Forum.Capabilities`, in
  ash-template's shape).
  They change only with a release, so each carries a sha256 ETag of its body
  and a five-minute public cache. No sign-in, no database.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Forum.Capabilities
  alias PatchbayWeb.SiteEdition

  @directory "priv/public"
  @files Map.new(
           ~w(openapi.json llms.txt llms_open.txt robots.txt agents.md),
           &{&1, Path.join(@directory, &1)}
         )
  for {_name, path} <- @files, do: @external_resource(path)

  # The open address has its own agent guide, with none of patchbay.help's
  # payments (`PatchbayWeb.SiteEdition`).
  @guides %{main: "llms.txt", open: "llms_open.txt"}

  @sources Map.new(@files, fn {name, path} -> {name, File.read!(path)} end)

  # The release time: security.txt expires a year after it.
  @released_at DateTime.utc_now() |> DateTime.truncate(:second)

  def openapi(conn, _params) do
    body = @sources["openapi.json"]
    conn |> cache(body) |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  def llms(conn, _params) do
    edition = conn.assigns.site_edition

    body =
      @sources[@guides[edition]]
      |> String.replace("{{facts}}", Patchbay.About.facts(edition))
      |> guide(edition)

    conn |> cache(body) |> put_resp_content_type("text/plain") |> send_resp(200, body)
  end

  def agents(conn, _params) do
    body =
      @sources["agents.md"]
      |> guide(:main)
      |> String.replace("{{origin}}", PatchbayWeb.Endpoint.url())

    conn |> cache(body) |> put_resp_content_type("text/markdown") |> send_resp(200, body)
  end

  def capabilities(conn, _params) do
    body =
      %{
        site: "patchbay",
        base_url: PatchbayWeb.Endpoint.url(),
        build: Application.fetch_env!(:patchbay, :build),
        cli: Capabilities.cli(),
        operations: Capabilities.operations()
      }
      |> Map.merge(Capabilities.authorities_and_conditions())
      |> Jason.encode!()

    conn |> cache(body) |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  # The guides' tool tables and install lines, from the manifest and the
  # capability rows, so neither guide names a tool or a release of its own;
  # each lists only the tools `edition`'s address offers.
  defp guide(text, edition) do
    cli = Capabilities.cli()

    more_tools =
      for tool <- Capabilities.more(), SiteEdition.offers?(edition, tool), do: "`#{tool.name}`"

    text
    |> String.replace("{{tools}}", Capabilities.tools_markdown())
    |> String.replace("{{more_tools}}", Enum.join(more_tools, ", "))
    |> String.replace("{{cli_install}}", Capabilities.cli_install())
    |> String.replace("{{cli_release}}", cli["release"])
    |> String.replace("{{cli_source}}", cli["source"])
    |> String.replace("{{cli_wheel_sha256}}", cli["wheel_sha256"])
  end

  def robots(conn, _params) do
    body = @sources["robots.txt"]
    conn |> cache(body) |> put_resp_content_type("text/plain") |> send_resp(200, body)
  end

  @doc "The RFC 9116 security contact; it expires a year after the release."
  def security(conn, _params) do
    body = """
    Contact: mailto:build@regents.sh
    Expires: #{@released_at |> DateTime.shift(year: 1) |> DateTime.to_iso8601()}
    Preferred-Languages: en
    Canonical: #{url(~p"/.well-known/security.txt")}
    Policy: #{url(~p"/contact")}
    """

    conn |> cache(body) |> put_resp_content_type("text/plain") |> send_resp(200, body)
  end

  @doc """
  The token OpenAI's plugin portal gives for proving this address is
  Patchbay's, as plain text. Not found until the token is set.
  """
  def openai_apps_challenge(conn, _params) do
    case Application.get_env(:patchbay, :openai_apps_challenge) do
      nil -> send_resp(conn, 404, "")
      token -> conn |> put_resp_content_type("text/plain") |> send_resp(200, token)
    end
  end

  @doc """
  The IndexNow key, which proves the pages this site sends to search engines
  came from it (`Patchbay.IndexNow`). Not found while no key is set.
  """
  def indexnow_key(conn, _params) do
    case Patchbay.IndexNow.key() do
      nil -> send_resp(conn, 404, "")
      key -> conn |> put_resp_content_type("text/plain") |> send_resp(200, key)
    end
  end

  @doc "The RFC 9727 API catalog: the API, its description and its documentation."
  # The body is JSON built from this site's own addresses, sent as a linkset with
  # the RFC 9727 profile, which Sobelow does not read as a safe content type.
  # sobelow_skip ["XSS.SendResp"]
  def api_catalog(conn, _params) do
    body =
      Jason.encode!(%{
        "linkset" => [
          %{
            "anchor" => url(~p"/"),
            "service-desc" => [%{"href" => url(~p"/openapi.json"), "type" => "application/json"}],
            "service-doc" => [%{"href" => url(~p"/docs"), "type" => "text/html"}]
          }
        ]
      })

    conn
    |> cache(body)
    |> put_resp_content_type(
      ~s(application/linkset+json; profile="https://www.rfc-editor.org/info/rfc9727"),
      nil
    )
    |> send_resp(200, body)
  end

  defp cache(conn, body) do
    conn
    |> put_resp_header("etag", ~s("#{Base.encode16(:crypto.hash(:sha256, body), case: :lower)}"))
    |> put_resp_header("cache-control", "public, max-age=300")
  end
end
