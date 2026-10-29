defmodule Patchbay.IndexNowTest do
  # Invariants for telling search engines about public pages:
  # - each release's sitemap is queued once, however often the hourly job runs;
  # - a thread that changes queues its own address, and nothing is queued without a key;
  # - the list carries this site's host, key and key file, and only this site's pages;
  # - an answer that would fail again stops for good; a busy one waits;
  # - an accepted list is logged with its page count.
  use PatchbayWeb.ConnCase, async: false

  use Oban.Testing, repo: Patchbay.Repo

  alias Patchbay.Forum
  alias Patchbay.Forum.PostAddress
  alias Patchbay.IndexNow
  alias PatchbayWeb.SitemapController

  setup do
    key = Application.get_env(:patchbay, :indexnow_key)
    Application.put_env(:patchbay, :indexnow_key, "test-indexnow-key")

    on_exit(fn ->
      if key,
        do: Application.put_env(:patchbay, :indexnow_key, key),
        else: Application.delete_env(:patchbay, :indexnow_key)
    end)
  end

  test "each release's pages are queued once, however often the hourly job runs" do
    for _hour <- 1..3, do: assert(:ok = perform_job(IndexNow, %{}))

    assert [job] = all_enqueued(worker: IndexNow)
    assert job.args["urls"] == SitemapController.urls()
    assert (PatchbayWeb.Endpoint.url() <> "/") in job.args["urls"]
  end

  test "a new thread queues its own address" do
    report = thread!()

    assert_enqueued(
      worker: IndexNow,
      args: %{"urls" => [PostAddress.url(report)]}
    )
  end

  test "with no key set, nothing is queued and nothing is sent" do
    Application.delete_env(:patchbay, :indexnow_key)

    assert :ok = perform_job(IndexNow, %{})
    thread!()
    assert [] = all_enqueued(worker: IndexNow)

    assert {:cancel, _no_key} =
             perform_job(IndexNow, %{"urls" => [PatchbayWeb.Endpoint.url() <> "/"]})
  end

  test "the list names this site, its key and the file that proves it" do
    url = PatchbayWeb.Endpoint.url()
    urls = [url <> "/", url <> "/docs"]
    test = self()

    Req.Test.stub(IndexNow, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:sent, conn.method, conn.host, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 202, "")
    end)

    assert :ok = perform_job(IndexNow, %{"urls" => urls})
    assert_receive {:sent, "POST", "api.indexnow.org", body}

    assert body == %{
             "host" => URI.parse(url).host,
             "key" => "test-indexnow-key",
             "keyLocation" => url <> "/indexnow-key.txt",
             "urlList" => urls
           }
  end

  test "an accepted list says so in the log, with how many pages it carried" do
    url = PatchbayWeb.Endpoint.url()
    Req.Test.stub(IndexNow, &Plug.Conn.send_resp(&1, 202, ""))
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = perform_job(IndexNow, %{"urls" => [url <> "/", url <> "/docs"]})
      end)

    assert log =~ "IndexNow answered 202 for 2 pages"
  end

  test "a refused list stops for good, and a busy answer waits" do
    urls = [PatchbayWeb.Endpoint.url() <> "/"]

    for {status, outcome} <- [
          {200, :ok},
          {422, :cancel},
          {403, :cancel},
          {429, :snooze},
          {503, :error}
        ] do
      Req.Test.stub(IndexNow, &Plug.Conn.send_resp(&1, status, ""))
      assert outcome(perform_job(IndexNow, %{"urls" => urls})) == outcome, "answer #{status}"
    end
  end

  test "the key file serves the key, and is not found without one", %{conn: conn} do
    assert conn |> get("/indexnow-key.txt") |> response(200) == "test-indexnow-key"

    Application.delete_env(:patchbay, :indexnow_key)
    assert build_conn() |> get("/indexnow-key.txt") |> response(404) == ""
  end

  # A report filed by Patchbay itself, as the agent readiness tests file one.
  defp thread! do
    site = Forum.register_site!("shop.example")

    tool =
      Forum.observe_tool!(%{
        site_id: site.id,
        address: "https://shop.example/",
        name: "checkout",
        contract_sha256: String.duplicate("a", 64)
      })

    Forum.file_report!(
      %{
        tool_id: tool.id,
        browser_session_id: Ash.UUID.generate(),
        arguments_sha256: String.duplicate("c", 64),
        verdict: :verified_success,
        note: "Checkout worked"
      },
      authorize?: false
    )
  end

  defp outcome(:ok), do: :ok
  defp outcome({outcome, _detail}), do: outcome
end
