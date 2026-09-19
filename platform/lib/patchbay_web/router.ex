defmodule PatchbayWeb.Router do
  use PatchbayWeb, :router

  pipeline :browser do
    plug :accepts, ["html", "md"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PatchbayWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug PatchbayWeb.Plugs.BrowserPolicy
    plug PatchbayWeb.Plugs.ForumSession, issue: true
    plug PatchbayWeb.Plugs.CurrentProfile
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PatchbayWeb do
    pipe_through :browser
    get "/blog", BlogController, :index
    get "/blog/:slug", BlogController, :show
    get "/help", PagesController, :help
    get "/about", PagesController, :about
    get "/contact", PagesController, :contact
    get "/privacy", PagesController, :privacy
    get "/changelog", PagesController, :changelog
    get "/runtime", PagesController, :runtime
    get "/developers", PagesController, :developers
    get "/webmcp", PagesController, :webmcp
    get "/docs", PagesController, :docs
  end

  scope "/", PatchbayWeb do
    get "/sitemap.xml", SitemapController, :index
  end

  pipeline :wallet_author do
    plug PatchbayWeb.Plugs.WalletAuthor
  end

  pipeline :hello_proof do
    plug PatchbayWeb.Plugs.HelloProof
  end

  scope "/api/agent", PatchbayWeb.ForumAPI do
    pipe_through [:api, :hello_proof]
    post "/hello", HelloController, :create
  end

  scope "/", PatchbayWeb.ForumAPI do
    pipe_through :api
    get "/hello", HelloController, :index
  end

  # The hosted MCP tools. One address takes every message; it keeps no stream
  # open, so anything but a POST is told so.
  scope "/", PatchbayWeb do
    pipe_through :api
    post "/mcp", MCPController, :message
    get "/mcp", MCPController, :not_allowed
    delete "/mcp", MCPController, :not_allowed
  end

  scope "/api/agent", PatchbayWeb.PaymentsAPI do
    pipe_through [:api, :wallet_author]
    post "/payment_intents", PaymentIntentController, :create
    post "/payment_intents/:id/execute", PaymentIntentController, :execute
    get "/payment_intents/:id", PaymentIntentController, :show
  end

  # Signing in and out. The browser proves itself with Privy tokens it carries
  # in headers, over the same signed session and forgery token a form would.
  pipeline :privy_session do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # Paid actions act on behalf of one signed-in profile and have no anonymous
  # form, so the request stops at the door when there is nobody behind it.
  pipeline :require_profile do
    plug PatchbayWeb.Plugs.RequireProfile
  end

  # What a payment files is filed under the browser's own forum identity, like
  # any other post. A page load would have issued one; a wallet paying from a
  # page that has not loaded since is issued one here, so the report it pays
  # for always has a session to stand under.
  pipeline :payments do
    plug PatchbayWeb.Plugs.ForumSession, issue: true
  end

  # The forum tools every page offers an agent post from the page itself, so
  # they carry the same signed session and forgery token a form would. The
  # answers are JSON, which is why this stands beside `:browser` rather than
  # inside it.
  pipeline :forum_tools do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug PatchbayWeb.Plugs.ForumSession
    plug PatchbayWeb.Plugs.CurrentProfile
  end

  scope "/webmcp", PatchbayWeb do
    pipe_through :browser

    # Retire the public demo entry without deleting existing rooms or evidence.
    get "/rooms/skill-uplift", Forum.BoardController, :retired_demo
    get "/rooms/busy", RoomController, :busy
  end

  # A room is a live page and nothing else; it does not answer as markdown.
  pipeline :html_only do
    plug :accepts, ["html"]
  end

  scope "/webmcp", PatchbayWeb.WebMCP do
    pipe_through [:browser, :html_only]

    live_session :webmcp, on_mount: [{PatchbayWeb.CurrentProfile, :default}] do
      live "/rooms/:slug", RoomLive.Show, :show
    end
  end

  scope "/auth/privy", PatchbayWeb do
    pipe_through :privy_session

    post "/session", PrivySessionController, :create
    delete "/session", PrivySessionController, :delete
  end

  scope "/forum", PatchbayWeb.ForumAPI do
    pipe_through :forum_tools

    post "/reports", ReportController, :create
    post "/reports/:id/replies", ReportController, :create_reply
    get "/reports/:id", ReportController, :show
    post "/threads", ReportController, :create_thread
    post "/threads/:id/replies", ReportController, :create_thread_reply
    post "/threads/:id/solution", ReportController, :mark_solution
    post "/replies/:id/uses", ReportController, :record_use
    post "/subscriptions", ReportController, :subscribe
    delete "/subscriptions/:id", ReportController, :unsubscribe
    get "/notifications", ReportController, :inbox
    post "/notifications/acknowledge", ReportController, :acknowledge
    get "/capabilities", ReportController, :capabilities
    get "/threads/:id", ReportController, :show
    get "/search", ReportController, :search
    get "/tool-history", ToolController, :index
  end

  scope "/", PatchbayWeb.ForumAPI do
    pipe_through :forum_tools
    post "/hello", HelloController, :create
  end

  scope "/forum", PatchbayWeb.ForumAPI do
    pipe_through [:forum_tools, :require_profile]

    post "/reports/:id/accept", SolutionController, :create
    post "/reports/:id/refund", RefundController, :create
  end

  scope "/api/v1" do
    pipe_through :api
    forward "/profile", RegentIdentity.HTTP, otp_app: :patchbay
  end

  scope "/api", PatchbayWeb.AgentAPI do
    pipe_through :forum_tools

    get "/agents/:public_id", ProfileController, :show
  end

  scope "/api", PatchbayWeb.IdentityAPI do
    pipe_through [:forum_tools, :require_profile]

    post "/me/agent_name", NameController, :agent
  end

  scope "/webmcp", PatchbayWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  scope "/api", PatchbayWeb.PaymentsAPI do
    pipe_through [:forum_tools, :payments, :require_profile]

    post "/payment_intents", PaymentIntentController, :create
    post "/payment_intents/:id/execute", PaymentIntentController, :execute
    get "/payment_intents/:id", PaymentIntentController, :show
    get "/me/usdc_balance", BalanceController, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", PatchbayWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:patchbay, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard",
        metrics: PatchbayWeb.Telemetry,
        csp_nonce_assign_key: :csp_nonce

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  scope "/", PatchbayWeb do
    pipe_through :browser

    get "/profile", SharedProfileController, :show
    get "/agents/:public_id", AgentProfileController, :show
    post "/agents/:public_id/names", AgentProfileController, :rename
  end

  scope "/", PatchbayWeb.Forum do
    pipe_through :browser

    get "/", BoardController, :home
    get "/ask", BoardController, :ask
    post "/threads", BoardController, :create_thread
    post "/threads/:id/replies", BoardController, :reply_thread
    get "/questions", BoardController, :questions
    get "/priority", BoardController, :priority
    get "/moderation", ModerationController, :index
    post "/moderation", ModerationController, :decide
    post "/follow", BoardController, :follow
    get "/inbox", BoardController, :inbox
    post "/inbox/acknowledge", BoardController, :acknowledge
    post "/posts/:id/solution", BoardController, :mark_solution
    get "/start", BoardController, :start
    get "/agent-setup", BoardController, :agent_setup
    post "/reports/:id/replies", BoardController, :create_reply
    post "/reports/:id/refund", BoardController, :refund
    post "/posts/:id/replies", BoardController, :create_reply
    post "/posts/:id/refund", BoardController, :refund
    get "/sites", BoardController, :sites
    get "/sites/:origin", BoardController, :site
    get "/sites/:origin/tools/:name", BoardController, :tool
    get "/posts/:id", BoardController, :post
    get "/reports/:id", BoardController, :report
  end
end
