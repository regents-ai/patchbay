defmodule PatchbayWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :patchbay

  # A stylesheet, an icon or an image may be opened directly, and the browser then
  # reads it as a page. These say what a page from this address may do, which is
  # nothing, as on every Regent site (ash-template's endpoint).
  @static_headers %{
    "content-security-policy" => "default-src 'none'; frame-ancestors 'none'",
    "x-content-type-options" => "nosniff",
    "x-frame-options" => "DENY",
    "referrer-policy" => "no-referrer"
  }

  # A video opened directly plays in a page of its own, which may load only
  # the video itself.
  @video_headers Map.put(
                   @static_headers,
                   "content-security-policy",
                   "default-src 'none'; media-src 'self'; frame-ancestors 'none'"
                 )

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_patchbay_key",
    signing_salt: "8IPnb8sh",
    same_site: "Lax",
    secure: Application.compile_env!(:patchbay, :secure_session_cookie),
    max_age: Application.compile_env!(:patchbay, :sign_in_lifetime_seconds)
  ]

  # fullsweep_after: 0 has each page's connection give back what it used to send
  # the page, the template's standard (ash-frontend, references/public-figures.md).
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options], fullsweep_after: 0],
    longpoll: [connect_info: [session: @session_options]]

  plug PatchbayWeb.Plugs.CanonicalHost
  # Which of the two addresses this is (PatchbayWeb.SiteEdition).
  plug PatchbayWeb.SiteEdition, :assign

  # The Wallet Bench and wallet articles keep their direct files at the same
  # address as their pages, including each file's digested copy.
  @static_files Plug.Static.init(
                  at: "/",
                  from: :patchbay,
                  gzip: not code_reloading?,
                  only: PatchbayWeb.static_paths(),
                  raise_on_missing_only: code_reloading?,
                  headers: @static_headers
                )
  @wallet_article_images ~w(agent-wallet-bench-v7- claude-code-wallets
                            where-agents-keep-keys which-wallets-agents-can-use)
  plug :serve_static_files

  # The ChatGPT plugin's review video (plugins/patchbay/plugin.json), kept out
  # of the digested assets.
  plug Plug.Static,
    at: "/videos",
    from: {:patchbay, "priv/videos"},
    headers: @video_headers

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint. In development the reloader
  # puts a frame from this site into every page; it answers that frame itself,
  # ahead of the page policy below, whose frame-ancestors 'none' would refuse it.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :patchbay
  end

  # Everything else is served under the strict policy unless its pipeline sets
  # another. Error pages carry it too, except in development, where the
  # debugger answers them (`debug_errors`, on by default there) and drops
  # the policy from its page.
  plug :put_reading_policy

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  # Which visit, and which kind of caller, each line of this request belongs to.
  plug PatchbayWeb.VisitLog
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # Before the body is parsed, so a body that cannot be read is refused in
  # the format chosen for its path: JSON under these prefixes, otherwise
  # whatever the caller's Accept header prefers.
  plug RegentAgentAccess.Plug,
    documents: &PatchbayWeb.PublicDocuments.document/1,
    guide: "/llms.txt",
    json_prefixes: ~w(api forum hello mcp chatgpt tools)

  # After the error format is chosen, so a slash address is answered as any
  # address that names nothing.
  plug PatchbayWeb.Plugs.NoTrailingSlash

  plug PatchbayWeb.Plugs.Parsers,
    body_reader: {PatchbayWeb.WalletBodyReader, :read_body, []},
    parsers: [Plug.Parsers.URLENCODED, Plug.Parsers.JSON],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug PatchbayWeb.Plugs.ReadBudget
  plug PatchbayWeb.Router

  defp serve_static_files(%{assigns: %{site_edition: :open}, path_info: path} = conn, _opts) do
    if main_asset?(Enum.map(path, &URI.decode/1)), do: conn, else: static(conn)
  end

  defp serve_static_files(conn, _opts), do: static(conn)
  defp static(conn), do: Plug.Static.call(conn, @static_files)

  defp main_asset?(["data", "agent-wallet-bench-v7" <> _suffix]), do: true
  defp main_asset?(["images", "wallet-bench" | _]), do: true

  defp main_asset?(["images", "blog", file]),
    do: String.starts_with?(file, @wallet_article_images)

  defp main_asset?(_path), do: false

  defp put_reading_policy(conn, _opts) do
    merge_resp_headers(conn, %{
      "content-security-policy" => PatchbayWeb.ContentSecurityPolicy.reading(),
      "x-content-type-options" => "nosniff",
      "referrer-policy" => "no-referrer"
    })
  end
end
