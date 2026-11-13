defmodule Patchbay.Incidents.CveNowTest do
  @moduledoc """
  cve.now's critical records copied into posts (`Patchbay.Incidents.CveNow`):
  - each record on the newest page gets one post, oldest first, on cve.now's
    board in Patchbay's name, and only the newest page is read;
  - a second run makes no post and reads no record again; a record cve.now
    changed has its post brought in line, and stays one post;
  - a record cve.now does not rate critical, or one not in the expected shape,
    is passed over and the rest are copied;
  - a read that fails, answers 503 or comes from cve.now's stale copy changes
    nothing and the next run carries on; a long Retry-After puts the job off;
  - two runs at once still make one post per record;
  - cve.now's words stay words: they add no heading or link to the post.

  cve.now is each test's own stand-in (`Req.Test`), never the internet.
  """

  use PatchbayWeb.ConnCase, async: false
  use Oban.Testing, repo: Patchbay.Repo

  @moduletag :capture_log

  alias Patchbay.Config
  alias Patchbay.Forum
  alias Patchbay.Forum.PostAddress
  alias Patchbay.Incidents.CveNow
  alias Patchbay.Incidents.CveNow.Post

  @older "CVE-2026-100001"
  @newer "CVE-2026-100002"

  defp entry(id, changes \\ %{}) do
    Map.merge(
      %{
        "type" => "cve",
        "kind" => "vulnerability",
        "id" => id,
        "title" => "Acme Gateway remote code execution in #{id}",
        "url" => "https://cve.now/" <> id,
        "modifiedAt" => "2026-11-12T10:00:00.000Z",
        "critical" => %{"value" => true, "reasons" => ["kev"]},
        "summary" => %{"text" => "Acme Gateway lets an attacker run code.", "model" => "m"},
        "severity" => %{"cvss" => 9.8, "vector" => "CVSS:3.1/AV:N", "source" => "cna"},
        "exploitation" => %{
          "kev" => %{"dateAdded" => "2026-11-10", "dueDate" => "2026-12-01"}
        },
        "vendors" => [%{"slug" => "acme", "name" => "Acme"}],
        "products" => [%{"slug" => "gateway", "vendor" => "acme", "name" => "Acme Gateway"}],
        "packages" => [],
        "fixedIn" => ["2.0.1"],
        "references" => [
          %{"url" => "https://acme.example/advisory", "type" => "fix", "role" => "vendor"}
        ]
      },
      changes
    )
  end

  defp item(entry), do: Map.take(entry, ["type", "id", "url", "title", "modifiedAt"])

  # cve.now as this test's stand-in: the list answers `entries`' items newest
  # first, and each entry answers itself, the first through a redirect to a
  # copy elsewhere as cve.now's CDN does. Every read is reported to the test.
  defp serve(entries) do
    test = self()
    [%{"id" => first} | _rest] = entries

    Req.Test.stub(CveNow, fn conn ->
      send(test, {:read, conn.host, conn.request_path, conn.query_string})

      case {conn.host, conn.request_path} do
        {"cve.now", "/api/v1/entries"} ->
          Req.Test.json(conn, %{"items" => Enum.map(entries, &item/1), "next_cursor" => "next"})

        {"cve.now", "/api/v1/entries/" <> ^first} ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://copies.example/entries/#{first}.json")
          |> Plug.Conn.send_resp(302, "")

        {_host, "/" <> path} ->
          id = path |> Path.basename() |> Path.rootname()
          Req.Test.json(conn, Enum.find(entries, &(&1["id"] == id)))
      end
    end)
  end

  defp posts do
    {:ok, posts} = Forum.list_cve_now_mirrors([@older, @newer, "CVE-2026-100003"])
    Enum.sort_by(posts, & &1.inserted_at, DateTime)
  end

  defp entry_reads do
    receive do
      {:read, _host, "/api/v1/entries/" <> _id, _query} -> 1 + entry_reads()
      {:read, _host, _path, _query} -> entry_reads()
    after
      0 -> 0
    end
  end

  test "each record on the newest page gets one post, oldest first, on cve.now's board in Patchbay's name",
       %{conn: conn} do
    serve([entry(@newer), entry(@older)])

    assert :ok = perform_job(CveNow, %{})

    # The newest page only: no cursor, so nothing before it is read.
    assert_received {:read, "cve.now", "/api/v1/entries", query}
    assert URI.decode_query(query) == %{"filter" => "critical,kev", "limit" => "50"}

    assert [older, newer] = posts()
    assert {older.cve_now_id, newer.cve_now_id} == {@older, @newer}
    assert older.title == "#{@older}: Acme Gateway remote code execution in #{@older}"
    assert older.topic_tags == [String.downcase(@older)]
    assert older.browser_session_id == Config.agent_session_id()
    assert older.thread_kind == :discussion
    assert older.body_markdown =~ "(<https://cve.now/#{@older}>)"

    {:ok, site} = Forum.register_site("cve.now")
    assert older.site_id == site.id

    # Advisories: on cve.now's board and the home page's Advisories tab, and
    # not among the home page's questions.
    home = conn |> get(~p"/") |> html_response(200)
    advisories = build_conn() |> get(~p"/?source_kind=advisory") |> html_response(200)
    board = build_conn() |> get("/" <> site.origin) |> html_response(200)

    for post <- [older, newer] do
      refute home =~ PostAddress.path(post)
      assert advisories =~ PostAddress.path(post)
      assert board =~ PostAddress.path(post)
    end
  end

  test "a second run makes no post and reads no record again" do
    serve([entry(@newer), entry(@older)])

    assert :ok = perform_job(CveNow, %{})
    assert entry_reads() == 2
    before = posts()

    assert :ok = perform_job(CveNow, %{})
    assert entry_reads() == 0
    assert posts() == before
  end

  test "a record cve.now changed has its one post brought in line" do
    serve([entry(@older)])
    assert :ok = perform_job(CveNow, %{})
    assert [post] = posts()

    changed =
      entry(@older, %{
        "title" => "Acme Gateway remote code execution, now fixed",
        "modifiedAt" => "2026-11-13T10:00:00.000Z",
        "fixedIn" => ["2.0.2"]
      })

    serve([changed])
    assert entry_reads() == 1
    assert :ok = perform_job(CveNow, %{})
    assert entry_reads() == 1

    assert [refreshed] = posts()
    assert refreshed.id == post.id
    assert refreshed.title == "#{@older}: Acme Gateway remote code execution, now fixed"
    assert refreshed.body_markdown =~ "2.0.2"
    refute refreshed.body_markdown =~ "2.0.1"
    assert DateTime.compare(refreshed.cve_now_modified_at, ~U[2026-11-13 10:00:00Z]) == :eq

    # Its list date no longer newer than the post's, it is not read again.
    assert :ok = perform_job(CveNow, %{})
    assert entry_reads() == 0
  end

  test "a record cve.now does not rate critical, or one not in the expected shape, is passed over" do
    not_critical = entry("CVE-2026-100003", %{"critical" => %{"value" => false, "reasons" => []}})
    untitled = entry(@newer, %{"title" => nil})

    test = self()

    Req.Test.stub(CveNow, fn conn ->
      send(test, {:read, conn.host, conn.request_path, conn.query_string})

      case conn.request_path do
        "/api/v1/entries" ->
          Req.Test.json(conn, %{
            "items" => [
              item(not_critical),
              %{"title" => "No id"},
              item(untitled),
              item(entry(@older))
            ]
          })

        "/api/v1/entries/" <> id ->
          Req.Test.json(
            conn,
            Enum.find([not_critical, untitled, entry(@older)], &(&1["id"] == id))
          )
      end
    end)

    assert :ok = perform_job(CveNow, %{})
    assert [%{cve_now_id: @older}] = posts()
  end

  test "a read that fails, answers 503 or is stale changes nothing, and the next run carries on" do
    for answer <- [
          &Req.Test.transport_error(&1, :timeout),
          &(&1 |> Plug.Conn.put_resp_header("retry-after", "5") |> Plug.Conn.send_resp(503, "")),
          &(&1
            |> Plug.Conn.put_resp_header("x-cve-now-stale", "120")
            |> Req.Test.json(%{"items" => [item(entry(@older))]}))
        ] do
      Req.Test.stub(CveNow, answer)
      assert :ok = perform_job(CveNow, %{})
      assert posts() == []
    end

    # A record that cannot be read ends the run; what was copied stays.
    test = self()

    Req.Test.stub(CveNow, fn conn ->
      send(test, {:read, conn.host, conn.request_path, conn.query_string})

      case conn.request_path do
        "/api/v1/entries" ->
          Req.Test.json(conn, %{"items" => Enum.map([entry(@newer), entry(@older)], &item/1)})

        "/api/v1/entries/" <> @older ->
          Req.Test.json(conn, entry(@older))

        "/api/v1/entries/" <> @newer ->
          Plug.Conn.send_resp(conn, 500, "")
      end
    end)

    assert :ok = perform_job(CveNow, %{})
    assert [%{cve_now_id: @older}] = posts()

    serve([entry(@newer), entry(@older)])
    assert :ok = perform_job(CveNow, %{})
    assert [%{cve_now_id: @older}, %{cve_now_id: @newer}] = posts()
  end

  test "a Retry-After longer than the time to the next run puts the job off that long" do
    Req.Test.stub(CveNow, fn conn ->
      conn |> Plug.Conn.put_resp_header("retry-after", "3600") |> Plug.Conn.send_resp(429, "")
    end)

    assert {:snooze, 3600} = perform_job(CveNow, %{})
    assert posts() == []
  end

  test "switched off, the job reads nothing" do
    settings = Application.fetch_env!(:patchbay, CveNow)
    Application.put_env(:patchbay, CveNow, Keyword.put(settings, :enabled?, false))
    on_exit(fn -> Application.put_env(:patchbay, CveNow, settings) end)

    serve([entry(@older)])
    assert :ok = perform_job(CveNow, %{})
    refute_received {:read, _host, _path, _query}
    assert posts() == []
  end

  test "two runs at once make one post per record" do
    test = self()
    records = [entry(@newer), entry(@older)]

    # Every entry read waits until both runs have asked for it, so both have
    # found no post for it before either writes one.
    Req.Test.stub(CveNow, fn conn ->
      case conn.request_path do
        "/api/v1/entries" ->
          Req.Test.json(conn, %{"items" => Enum.map(records, &item/1)})

        "/api/v1/entries/" <> id ->
          send(test, {:waiting, id, self()})

          receive do
            :go -> Req.Test.json(conn, Enum.find(records, &(&1["id"] == id)))
          end
      end
    end)

    {outcomes, log} =
      ExUnit.CaptureLog.with_log(fn ->
        runs = for _run <- 1..2, do: Task.async(fn -> CveNow.perform(%Oban.Job{}) end)

        for id <- [@older, @newer] do
          waiting =
            for _run <- 1..2 do
              assert_receive {:waiting, ^id, pid}, 5_000
              pid
            end

          Enum.each(waiting, &send(&1, :go))
        end

        Task.await_many(runs, 15_000)
      end)

    # The run that wrote second found the first's post: nothing was passed over.
    assert outcomes == [:ok, :ok]
    refute log =~ "passed over"
    assert [%{cve_now_id: @older}, %{cve_now_id: @newer}] = posts()
  end

  test "cve.now's words add no heading, list or link of their own to the post" do
    {:ok, post} =
      entry(@older, %{
        "summary" => %{
          "text" => "# Owned\n\n- step [click](javascript:alert(1)) <b>bold</b> *loud*"
        }
      })
      |> Post.from_entry()

    html = post.body |> PatchbayWeb.Forum.BoardHTML.markdown() |> Phoenix.HTML.safe_to_string()
    [opening | _sections] = String.split(html, "<h2>")

    refute opening =~ "<h1"
    refute opening =~ "<li"
    refute opening =~ "<a "
    refute opening =~ "<b>"
    refute opening =~ "<em>"
    assert opening =~ "javascript:alert(1)"
  end
end
