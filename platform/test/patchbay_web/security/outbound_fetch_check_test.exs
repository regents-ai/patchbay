defmodule Patchbay.Security.PublicLookingSite do
  @moduledoc """
  The Req adapter behind the public-looking names in
  `Patchbay.Security.OutboundFetchCheckTest`. The one public address they
  resolve to is answered here and never reaches the network. Every other
  request goes out for real through Finch, so a hop that was let through
  shows on the check's listener or as an outbound connection.
  """

  @public_ip "93.184.216.34"

  def run(%Req.Request{url: %URI{host: @public_ip}} = request) do
    port = Application.fetch_env!(:patchbay, :outbound_fetch_check_port)
    host = request |> Req.Request.get_header("host") |> List.first()
    {status, headers, body} = page(host, request.method, request.url.path, port)
    # A body as iodata is left undecoded, as Target's own bounded reads leave it.
    {request, Req.Response.new(status: status, headers: headers, body: [body])}
  end

  def run(request), do: Req.Finch.run(request)

  defp page("redirect-name.com", _method, _path, port),
    do: {302, [{"location", "http://127.0.0.1:#{port}/"}], ""}

  defp page("redirect-tls-name.com", _method, _path, port),
    do: {302, [{"location", "https://127.0.0.1:#{port}/"}], ""}

  defp page("card-name.com", :get, "/.well-known/mcp.json", port) do
    endpoints =
      for host <- loopbacks(port), do: %{"url" => "https://#{host}/mcp"}

    {200, [{"content-type", "application/json"}],
     Jason.encode!(%{"name" => "Card", "endpoints" => endpoints})}
  end

  defp page("scripts-name.com", :get, "/", port) do
    scripts =
      for host <- loopbacks(port),
          do: ~s(<script type="module" src="https://#{host}/tools.js"></script>)

    {200, [{"content-type", "text/html"}], "<html><body>#{scripts}</body></html>"}
  end

  defp page(_host, _method, _path, _port), do: {404, [{"content-type", "text/plain"}], "not here"}

  defp loopbacks(port),
    do: ["127.0.0.1:#{port}", "localhost:#{port}", "[::1]:#{port}", "loopback-name.com"]
end

defmodule Patchbay.Security.OutboundFetchCheckTest do
  @moduledoc """
  Checks that every Patchbay feature that reads an address someone else
  named stays off this machine, private networks and cloud metadata, judged
  by whether anything actually connects.

  A plain TCP listener is opened on 127.0.0.1 (and ::1, on the same port)
  and counts every connection it accepts. Every outbound connection Finch
  opens is counted too, from its `[:finch, :connect, :start]` event, so a
  try at an address with nothing listening (169.254.169.254, port 443 on
  this machine) still shows. Each feature is then asked to read:

    * http://127.0.0.1:PORT/, http://localhost:PORT/, http://[::1]:PORT/,
      http://0.0.0.0:PORT/ and http://169.254.169.254/latest/meta-data/;
    * https://127.0.0.1:PORT/, the same loopback over https;
    * `loopback-name.com`, a name that resolves to 127.0.0.1, on port 443 and
      on PORT (through the features' own `resolve`/`lookup` hooks);
    * `redirect-name.com` and `redirect-tls-name.com`, public-looking pages
      whose every address redirects to http://127.0.0.1:PORT/ and
      https://127.0.0.1:PORT/;
    * for the site check, `card-name.com`, whose MCP server card names
      loopback servers, and for the assist, `scripts-name.com`, whose page
      loads its scripts from loopback.

  The public-looking pages are answered by a Req adapter in this file, for
  the one public address they resolve to. That is `Patchbay.PageSite`'s
  address, but `PageSite` answers every request itself, which would hide a
  redirect's next hop from the network; this adapter answers the public
  address only and lets every other request reach the network for real.

  Every feature must end with its normal refusal, the listener must accept
  nothing, and no outbound connection may be opened. Each test prints one
  line per address: what it was asked, what it answered, and both counts.
  """

  use PatchbayWeb.ConnCase, async: false
  use Oban.Testing, repo: Patchbay.Repo

  @moduletag :capture_log
  @moduletag timeout: 600_000

  alias Patchbay.Assist.Discovery
  alias Patchbay.Assist.Request
  alias Patchbay.Assist.Target
  alias Patchbay.Forum
  alias Patchbay.Offers.Destination
  alias PatchbayWeb.Forum.SiteChecks

  # `Patchbay.PageSite`'s address: the one every public-looking name here has.
  @public {93, 184, 216, 34}
  @public_names ~w(redirect-name.com redirect-tls-name.com card-name.com scripts-name.com)

  @picture "RIFF" <> <<4::little-32>> <> "WEBP" <> "VP8 "

  setup do
    {port, sockets} = listen!()
    test = self()
    for socket <- sockets, do: spawn(fn -> accept(socket, test) end)

    handler = "outbound-fetch-check-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, [:finch, :connect, :start], &__MODULE__.connecting/4, test)

    old_target = Application.get_env(:patchbay, :assist_target)
    old_shots = Application.get_env(:patchbay, :shots_req_options)

    Application.put_env(:patchbay, :assist_target, target_options())
    Application.put_env(:patchbay, :outbound_fetch_check_port, port)

    Application.put_env(:patchbay, :shots_req_options,
      plug: fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:shot, conn.host, Jason.decode!(body)["url"]})
        Plug.Conn.send_resp(conn, 200, @picture)
      end
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      Enum.each(sockets, &:gen_tcp.close/1)
      Application.put_env(:patchbay, :assist_target, old_target)
      Application.put_env(:patchbay, :shots_req_options, old_shots)
      Application.delete_env(:patchbay, :outbound_fetch_check_port)
    end)

    %{port: port}
  end

  # ---------------------------------------------------------------------------
  # The listener and the count of outbound connections

  # A free port on 127.0.0.1 that is free on ::1 too.
  defp listen!(tries \\ 10)
  defp listen!(0), do: raise("no port free on both 127.0.0.1 and ::1")

  defp listen!(tries) do
    {:ok, v4} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(v4)

    case :gen_tcp.listen(port, [:binary, :inet6, active: false, ip: {0, 0, 0, 0, 0, 0, 0, 1}]) do
      {:ok, v6} ->
        {port, [v4, v6]}

      {:error, _taken} ->
        :gen_tcp.close(v4)
        listen!(tries - 1)
    end
  end

  defp accept(socket, test) do
    case :gen_tcp.accept(socket) do
      {:ok, connection} ->
        send(test, :listener_accepted)
        :gen_tcp.close(connection)
        accept(socket, test)

      {:error, _closed} ->
        :ok
    end
  end

  @doc false
  def connecting(_event, _measurements, metadata, test),
    do: send(test, {:outbound_connect, "#{metadata.scheme}://#{metadata.host}:#{metadata.port}"})

  # Everything counted since the last look.
  defp counted do
    {accepted(0), opened([])}
  end

  defp accepted(count) do
    receive do
      :listener_accepted -> accepted(count + 1)
    after
      0 -> count
    end
  end

  defp opened(found) do
    receive do
      {:outbound_connect, where} -> opened([where | found])
    after
      0 -> found |> Enum.reverse() |> Enum.uniq()
    end
  end

  # ---------------------------------------------------------------------------
  # The addresses, and the public-looking site that answers some of them

  defp targets(port) do
    [
      {"loopback", "http://127.0.0.1:#{port}/"},
      {"localhost", "http://localhost:#{port}/"},
      {"IPv6 loopback", "http://[::1]:#{port}/"},
      {"0.0.0.0", "http://0.0.0.0:#{port}/"},
      {"cloud metadata", "http://169.254.169.254/latest/meta-data/"},
      {"loopback over https", "https://127.0.0.1:#{port}/"},
      {"name -> 127.0.0.1", "https://loopback-name.com/"},
      {"name -> 127.0.0.1, PORT", "https://loopback-name.com:#{port}/"},
      {"redirect -> http loopback", "https://redirect-name.com/"},
      {"redirect -> https loopback", "https://redirect-tls-name.com/"}
    ]
  end

  defp target_options do
    [
      resolve: &addresses/1,
      lookup: &{:ok, addresses(&1)},
      req_options: [adapter: Patchbay.Security.PublicLookingSite]
    ]
  end

  defp addresses("loopback-name.com"), do: [{127, 0, 0, 1}]
  defp addresses(host) when host in @public_names, do: [@public]
  defp addresses("localhost"), do: Target.resolve("localhost")

  # An address written as one is itself; any other name has none here, so
  # no resolver outside this machine is ever asked.
  defp addresses(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> [address]
      {:error, _a_name} -> []
    end
  end

  # ---------------------------------------------------------------------------
  # Asking, printing and judging

  # Asks `feature` for every address, then prints and judges each answer.
  # `refused?` says whether an answer is the feature's normal refusal.
  defp run_feature(name, addresses, ask, refused?) do
    _stale = counted()

    rows =
      for {label, url} <- addresses do
        answer = ask.(url)
        {accepted, opened} = counted()
        {label, url, answer, accepted, opened}
      end

    IO.puts("\n#{name}")

    for {label, url, answer, accepted, opened} <- rows do
      IO.puts(
        "  #{String.pad_trailing(label, 27)} #{String.pad_trailing(url, 42)} " <>
          "listener #{accepted}  outbound #{inspect(opened)}  #{inspect(answer, limit: 12)}"
      )
    end

    failures =
      for {label, url, answer, accepted, opened} <- rows,
          accepted > 0 or opened != [] or not refused?.(answer),
          do:
            "#{label} (#{url}): listener #{accepted}, outbound #{inspect(opened)}, #{inspect(answer)}"

    assert failures == [],
           "#{name}: expected every address refused with nothing connecting, but:\n  " <>
             Enum.join(failures, "\n  ")
  end

  defp drain_site_checks, do: Oban.drain_queue(queue: :site_checks)

  defp drain_pictures,
    do: Oban.drain_queue(queue: :site_pictures, with_scheduled: true, with_recursion: true)

  # ---------------------------------------------------------------------------
  # The features

  test "the site check reads nothing off the public internet", %{port: port} do
    # A check is of a registrable domain, so a port names the same site.
    addresses =
      (targets(port) ++ [{"card naming loopback servers", "https://card-name.com/"}])
      |> Enum.uniq_by(fn {_label, url} -> site_or_address(url) end)

    run_feature(
      "Site check (SiteChecks.ask -> SiteCheck :request -> its :run job -> SiteScan)",
      addresses,
      fn url ->
        case Forum.request_site_check(url) do
          {:error, error} ->
            {:refused, error |> Ash.Error.to_error_class() |> Exception.message() |> must_line()}

          {:ok, check} ->
            drain_site_checks()
            findings = Forum.get_site_check!(check.domain).findings

            {:checked, check.domain,
             %{
               page: findings["page_url"],
               webmcp: length(findings["webmcp"]),
               servers: findings["servers"],
               files: length(findings["files"])
             }}
        end
      end,
      fn
        {:refused, _message} ->
          true

        # A server a card names is listed as not answering, never reached.
        {:checked, _domain, %{page: nil, webmcp: 0, servers: servers, files: 0}} ->
          Enum.all?(servers, &(&1["answered"] == false))

        _read_something ->
          false
      end
    )
  end

  test "'Refresh this site' reads nothing off the public internet", %{port: port} do
    # The visitor's button: a new check and a new picture.
    run_feature(
      "Refresh this site (SiteChecks.refresh: its check, and its picture via the screenshot service)",
      targets(port)
      |> Enum.filter(fn {_label, url} -> match?({:ok, _}, Forum.Origin.normalize(url)) end)
      |> Enum.uniq_by(fn {_label, url} -> site_or_address(url) end),
      fn url ->
        {:ok, origin} = Forum.Origin.normalize(url)
        _site = Forum.register_site!(origin)
        site = Forum.get_site_by_origin!(origin, load: [:refresh_due?])

        {answer, _check} =
          SiteChecks.refresh(site, SiteChecks.current(origin), "visitor-#{origin}")

        drain_site_checks()
        drain_pictures()

        shots =
          receive do
            {:shot, shots_host, page} -> {shots_host, page}
          after
            0 -> nil
          end

        %{findings: findings} = Forum.get_site_check!(origin)
        {answer, page: findings["page_url"], servers: findings["servers"], picture_asked: shots}
      end,
      fn
        {:ok, page: nil, servers: [], picture_asked: {"patchbay-shots.flycast", "https://" <> _}} ->
          true

        _other ->
          false
      end
    )
  end

  # The daily refresh also reads the site's official source, an address the
  # directory's catalog names.
  test "the daily refresh reads no official source off the public internet", %{port: port} do
    run_feature(
      "Daily refresh, official source (Site :refresh -> RefreshSite.source_mentions_webmcp?)",
      targets(port),
      fn url ->
        origin = "source-#{System.unique_integer([:positive])}.example"
        Forum.upsert_catalog_entry!(origin, %{support_evidence_url: url})
        site = Forum.get_site_by_origin!(origin)

        refreshed =
          site |> Ash.Changeset.for_update(:refresh, %{}) |> Ash.update!(authorize?: false)

        {:verified_at, refreshed.last_verified_at}
      end,
      &match?({:verified_at, nil}, &1)
    )
  end

  test "the post form's site address check reads nothing off the public internet", %{port: port} do
    run_feature(
      "Post form site check (GET /fix-check -> FixCheck -> Discovery)",
      targets(port),
      fn url ->
        conn = build_conn() |> get(~p"/fix-check", %{"site_url" => url})
        body = Jason.decode!(conn.resp_body)
        {conn.status, body["status"], body["said"]}
      end,
      fn
        {422, "invalid", _said} -> true
        {200, "unreachable", said} -> said =~ "off the public internet"
        _other -> false
      end
    )
  end

  test "an Offer's link check visits nothing off the public internet", %{port: port} do
    run_feature(
      "Offer destination check (Screening -> Destination.visit)",
      targets(port),
      fn url ->
        {evidence, excerpt} = Destination.visit(url, target_options())
        {evidence["outcome"], evidence["hops"], excerpt}
      end,
      fn {outcome, _hops, excerpt} ->
        outcome in ["not_https", "not_public"] and is_nil(excerpt)
      end
    )
  end

  # An assist's run is asked for one site, and every page, script, file and
  # MCP call of it goes through Assist.Target.
  test "an assist's address is a public https name", %{port: port} do
    # An assist's run is asked only for an address Request.site_url admits;
    # the rest are refused before any run exists.
    run_feature(
      "Assist run's address (Assist.Request.site_url)",
      targets(port),
      &Request.site_url/1,
      fn
        {:error, {:invalid, _rules}} -> true
        {:ok, "https://" <> rest} -> String.starts_with?(rest, ["loopback-name.com/", "redirect"])
      end
    )
  end

  test "an assist's site reader reaches no site off the public internet", %{port: port} do
    run_feature(
      "Assist's site reader (Discovery.find: McpClient over Target, then PageTools)",
      targets(port) ++ [{"page loading loopback scripts", "https://scripts-name.com/"}],
      &Discovery.find(&1, target_options()),
      fn
        {:unlisted, :not_public} -> true
        {:unlisted, :no_tools_found} -> true
        _found -> false
      end
    )
  end

  test "Assist.Target reads no page off the public internet", %{port: port} do
    run_feature(
      "Assist.Target.get (every page, script and file read)",
      targets(port),
      &Target.get(&1, Keyword.put(target_options(), :redirects, 3)),
      &match?({:error, :not_public}, &1)
    )
  end

  defp site_or_address(url) do
    case Forum.Origin.normalize(url) do
      {:ok, domain} -> domain
      {:error, _not_a_site} -> url
    end
  end

  # The line of an error that says what the address must be.
  defp must_line(text),
    do:
      text |> String.split("\n", trim: true) |> Enum.find(text, &(&1 =~ "must")) |> String.trim()
end
