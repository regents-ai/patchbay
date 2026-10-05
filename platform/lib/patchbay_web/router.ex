defmodule PatchbayWeb.Router do
  use PatchbayWeb, :router

  alias PatchbayWeb.ContentSecurityPolicy

  pipeline :browser do
    plug :accepts, ["html", "md"]
    plug :fetch_session
    plug :fetch_live_flash
    plug PatchbayWeb.Plugs.Theme
    plug :put_root_layout, html: {PatchbayWeb.Layouts, :root}
    plug :protect_from_forgery

    # Every page carries the sign-in button.
    plug :put_secure_browser_headers, %{
      "content-security-policy" => ContentSecurityPolicy.sign_in()
    }

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
    get "/terms", PagesController, :terms
    get "/changelog", PagesController, :changelog
    get "/runtime", PagesController, :runtime
    get "/developers", PagesController, :developers
    get "/webmcp", PagesController, :webmcp
    get "/docs", PagesController, :docs
  end

  scope "/", PatchbayWeb do
    get "/sitemap.xml", SitemapController, :index
    get "/openapi.json", DiscoveryController, :openapi
    get "/llms.txt", DiscoveryController, :llms
    get "/robots.txt", DiscoveryController, :robots
    get "/.well-known/security.txt", DiscoveryController, :security
    get "/.well-known/api-catalog", DiscoveryController, :api_catalog
    get "/site-screenshots/:site_id", SiteScreenshotController, :show
    get "/post-pictures/:id", PostPictureController, :show
    get "/skill.md", AgentSkillsController, :guide
    get "/.well-known/skills/index.json", AgentSkillsController, :index
    get "/.well-known/skills/:name/SKILL.md", AgentSkillsController, :show
  end

  pipeline :wallet_author do
    plug PatchbayWeb.Plugs.WalletAuthor
  end

  pipeline :hello_proof do
    plug PatchbayWeb.Plugs.HelloProof
  end

  pipeline :siwa_test do
    plug PatchbayWeb.Plugs.SiwaTestProof
  end

  # Read-only proof that an agent's SIWA sign-in works here. It answers JSON
  # whatever the request accepts, so a person opening it sees the refusal too.
  scope "/", PatchbayWeb do
    pipe_through :siwa_test
    get "/siwa-test", SiwaTestController, :show
  end

  scope "/api/agent", PatchbayWeb.ForumAPI do
    pipe_through [:api, :hello_proof]
    post "/hello", HelloController, :create
  end

  scope "/", PatchbayWeb.ForumAPI do
    pipe_through :api
    get "/hello", HelloController, :index
  end

  # The hosted MCP tools. Each address takes every message for its door; it
  # keeps no stream open, so anything but a POST is told so. `/mcp` is every
  # agent's; `/chatgpt/mcp` is the ChatGPT plugin's, which never carries
  # Agent Offers. The route, not the caller, says which door it is.
  # Sobelow's "CSRF via action reuse" for GET and DELETE sharing :not_allowed
  # is recorded in .sobelow-skips: that action only refuses and changes nothing.
  scope "/", PatchbayWeb do
    pipe_through :api
    # Neither address is logged: an events subscription carries its webhook
    # signing secret and callback address in the params, and tool calls carry
    # what people wrote.
    post "/mcp", MCPController, :message, log: false, assigns: %{mcp_surface: :native_mcp}
    get "/mcp", MCPController, :not_allowed
    delete "/mcp", MCPController, :not_allowed

    post "/chatgpt/mcp", MCPController, :message,
      log: false,
      assigns: %{mcp_surface: :chatgpt_plugin}

    get "/chatgpt/mcp", MCPController, :not_allowed
    delete "/chatgpt/mcp", MCPController, :not_allowed
  end

  # The free fix's look for a site's WebMCP tools, asked as an address is typed.
  scope "/", PatchbayWeb.Forum do
    pipe_through :api
    get "/fix-check", FixCheckController, :show
  end

  # Jev's free look at the known fixes for a site, and an agent's word on
  # whether one worked, which needs only the decision id it was handed.
  scope "/", PatchbayWeb do
    pipe_through :api
    get "/known-fixes", KnownFixController, :show
    post "/known-fixes/:id", KnownFixController, :report
  end

  # A payment request draws on the share of the wallet it acts for, once the
  # pipeline before it has said which wallet that is.
  pipeline :payment_budget do
    plug PatchbayWeb.Plugs.PaymentBudget
  end

  scope "/api/agent", PatchbayWeb.PaymentsAPI do
    pipe_through [:api, :wallet_author, :payment_budget]
    post "/payment_intents", PaymentIntentController, :create
    post "/payment_intents/:id/execute", PaymentIntentController, :execute
    get "/payment_intents/:id", PaymentIntentController, :show
  end

  scope "/api/agent", PatchbayWeb.AssistAPI do
    pipe_through [:api, :wallet_author]
    post "/assists", RunController, :create
    get "/assists/:id", RunController, :show
  end

  # Signing in and out. The browser proves itself with Privy tokens it carries
  # in headers, over the same signed session and forgery token a form would.
  # JSON answers only, so there is no page for a policy to cover.
  # sobelow_skip ["Config.CSP"]
  pipeline :privy_session do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug PatchbayWeb.Plugs.ForumSession
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
  # JSON answers only, so there is no page for a policy to cover.
  # sobelow_skip ["Config.CSP"]
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
  # Always piped after `:browser`, which sets the secure headers.
  # sobelow_skip ["Config.Headers"]
  pipeline :html_only do
    plug :accepts, ["html"]
  end

  scope "/webmcp", PatchbayWeb.WebMCP do
    pipe_through [:browser, :html_only]

    live_session :webmcp, on_mount: [{PatchbayWeb.CurrentProfile, :default}] do
      live "/rooms/:slug", RoomLive.Show, :show
    end
  end

  # A fix is watched as it happens, so its page is live like a room's.
  scope "/", PatchbayWeb do
    pipe_through [:browser, :html_only]

    live_session :fixes, on_mount: [{PatchbayWeb.CurrentProfile, :default}] do
      live "/fixes/:id", FixLive.Show, :show
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
    get "/requests/:client_request_id", ReportController, :request_status
    post "/threads/:id/solution", ReportController, :mark_solution
    post "/replies/:id/uses", ReportController, :record_use
    post "/subscriptions", ReportController, :subscribe
    delete "/subscriptions/:id", ReportController, :unsubscribe
    get "/updates", ReportController, :updates
    get "/capabilities", ReportController, :capabilities
    get "/readiness", ReportController, :readiness
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
    post "/threads/:id/likes", LikeController, :create
    delete "/threads/:id/likes", LikeController, :delete
  end

  scope "/api/v1" do
    pipe_through :api
    forward "/profile", RegentIdentity.HTTP, otp_app: :patchbay
  end

  # An agent pairs with a person's Regent account, and checks in on it, the
  # same way on every Regent site. Pairing grants nothing here.
  scope "/api/agents/v1" do
    pipe_through :api
    forward "/", RegentAgents.HTTP
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

  # Only a new payment draws on the share. Paying it and reading it back do
  # not, so a signature the wallet has given is never turned away for count.
  scope "/api", PatchbayWeb.PaymentsAPI do
    pipe_through [:forum_tools, :payments, :require_profile, :payment_budget]

    post "/payment_intents", PaymentIntentController, :create
  end

  # Reading a paid assist back is not a payment request either.
  scope "/api", PatchbayWeb.AssistAPI do
    pipe_through [:forum_tools, :require_profile]
    get "/assists/:id", RunController, :show
  end

  # Paying a frozen intent, reading it back and reading the wallet's balance
  # draw on no share.
  scope "/api", PatchbayWeb.PaymentsAPI do
    pipe_through [:forum_tools, :payments, :require_profile]
    post "/payment_intents/:id/execute", PaymentIntentController, :pay
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

    # The dashboard and the mailbox write their own script and style elements.
    pipeline :dev_tools do
      plug :put_secure_browser_headers, %{
        "content-security-policy" =>
          "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:"
      }
    end

    scope "/dev" do
      pipe_through [:browser, :dev_tools]

      live_dashboard "/dashboard", metrics: PatchbayWeb.Telemetry

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # The payments lab, on a machine of ours only; its code is not in a release.
  if Application.compile_env(:patchbay, :payments_lab) do
    scope "/dev/lab/payments", PatchbayDev do
      pipe_through :browser
      get "/", PaymentsLab, :show
      post "/sign-in", PaymentsLab, :sign_in
    end

    scope "/dev/lab/payments", PatchbayDev do
      pipe_through :forum_tools
      post "/wallet", PaymentsLab, :wallet
    end

    scope "/dev/lab/payments", PatchbayDev do
      post "/facilitator/verify", LabFacilitator, :verify
      post "/facilitator/settle", LabFacilitator, :settle
    end
  end

  scope "/", PatchbayWeb do
    pipe_through :browser

    get "/profile", SharedProfileController, :show
    get "/agents/:public_id", AgentProfileController, :show
    get "/discuss/techtree/:digest", TechtreeDiscussionController, :show
    post "/agents/:public_id/names", AgentProfileController, :rename
  end

  scope "/", PatchbayWeb.Forum do
    pipe_through :browser

    get "/", BoardController, :home
    post "/fixes", BoardController, :fix
    post "/threads", BoardController, :create_thread
    # The same form on a page of its own look, for personal agents and the
    # people who use them; a turned-down fix or post comes back to that page.
    get "/o", BoardController, :home, private: %{home_page: :o}
    post "/o/fixes", BoardController, :fix, private: %{home_page: :o}
    post "/o/threads", BoardController, :create_thread, private: %{home_page: :o}
    post "/threads/preview", BoardController, :preview_thread
    post "/threads/:id/replies", BoardController, :reply_thread
    get "/questions", BoardController, :questions
    get "/priority", BoardController, :priority
    get "/moderation", ModerationController, :index
    post "/moderation", ModerationController, :decide
    post "/follow", BoardController, :follow
    get "/inbox", BoardController, :inbox
    post "/inbox/acknowledge", BoardController, :acknowledge
    post "/posts/:id/solution", BoardController, :mark_solution
    post "/posts/:id/likes", BoardController, :like
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
