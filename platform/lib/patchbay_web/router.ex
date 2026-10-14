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
    plug PatchbayWeb.Plugs.CurrentEns
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
    get "/wallet-bench", WalletBenchController, :index
    get "/wallet-bench/:harness_id/:wallet_id", WalletBenchController, :show
  end

  scope "/", PatchbayWeb do
    get "/sitemap.xml", SitemapController, :index
    get "/openapi.json", DiscoveryController, :openapi
    get "/llms.txt", DiscoveryController, :llms
    get "/agents.md", DiscoveryController, :agents
    get "/robots.txt", DiscoveryController, :robots
    get "/.well-known/security.txt", DiscoveryController, :security
    get "/.well-known/api-catalog", DiscoveryController, :api_catalog
    get "/.well-known/openai-apps-challenge", DiscoveryController, :openai_apps_challenge
    get "/site-screenshots/:site_id", SiteScreenshotController, :show
    get "/post-pictures/:id", PostPictureController, :show
    get "/skill.md", AgentSkillsController, :guide
    get "/.well-known/skills/index.json", AgentSkillsController, :index
    get "/.well-known/skills/:name/SKILL.md", AgentSkillsController, :show
  end

  # Each pipeline that checks a signature counts the request for its address
  # first, so the sign-in service is never asked on an uncounted request.
  pipeline :wallet_author do
    plug PatchbayWeb.Plugs.SignedBudget
    plug PatchbayWeb.Plugs.WalletAuthor
  end

  pipeline :paired_agent do
    plug PatchbayWeb.Plugs.SignedBudget
    plug PatchbayWeb.Plugs.PairedAgent
  end

  pipeline :agent_payment_admission do
    plug PatchbayWeb.Plugs.AgentPaymentAdmission
  end

  pipeline :hello_proof do
    plug PatchbayWeb.Plugs.SignedBudget
    plug PatchbayWeb.Plugs.HelloProof
  end

  # The Wallet Bench's paid-call test: 0.01 USDC by x402, then a fixed answer.
  pipeline :x402_test do
    plug :accepts, ["json"]
    plug PatchbayWeb.Plugs.X402Test
  end

  scope "/bench", PatchbayWeb do
    pipe_through :x402_test
    get "/x402-test", X402TestController, :show
  end

  pipeline :siwa_test do
    plug PatchbayWeb.Plugs.SignedBudget
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
  end

  # The agent pages, one per agent program, each at its own address.
  @agent_pages ~w(dots muse grokbot hermes claude)

  # Each agent page's steps on their own, as the agents.md that agent reads.
  scope "/", PatchbayWeb.Forum do
    for agent <- @agent_pages do
      get "/#{agent}/agents.md", BoardController, :agent_guide, private: %{home_page: agent}
    end
  end

  # A payment request draws on the share of the wallet it acts for, once the
  # pipeline before it has said which wallet that is.
  pipeline :payment_budget do
    plug PatchbayWeb.Plugs.PaymentBudget
  end

  scope "/api/agent", PatchbayWeb.PaymentsAPI do
    pipe_through [:api, :paired_agent, :payment_budget]
    post "/payment_intents", PaymentIntentController, :create
    get "/payment_intents/:id", PaymentIntentController, :show
  end

  # New settlement locks current delegation in the shared purchase layer.
  scope "/api/agent", PatchbayWeb.PaymentsAPI do
    pipe_through [:api, :wallet_author, :agent_payment_admission]
    post "/payment_intents/:id/execute", PaymentIntentController, :execute
  end

  # An original signer may finish only its already authorized payment.
  scope "/api/agent", PatchbayWeb.PaymentsAPI do
    pipe_through [:api, :wallet_author]
    post "/payment_intents/:id/complete", PaymentIntentController, :complete
  end

  scope "/api/agent", PatchbayWeb.AssistAPI do
    pipe_through [:api, :paired_agent]
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

  # What a page asks for the person looking at it: what Patchbay knows of
  # them, their name, their payments, an answer they accept. Each call carries
  # the same signed session and forgery token a form would. No post comes this
  # way: an agent posts with a signed request, through `:paired_agent`.
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
  end

  # A room is a live page and nothing else; it does not answer as markdown.
  # Always piped after `:browser`, which sets the secure headers.
  # sobelow_skip ["Config.Headers"]
  pipeline :html_only do
    plug :accepts, ["html"]
  end

  pipeline :no_store do
    plug :put_no_store
  end

  scope "/webmcp", PatchbayWeb.WebMCP do
    pipe_through [:browser, :html_only]

    live_session :webmcp, on_mount: [{PatchbayWeb.CurrentProfile, :default}] do
      live "/rooms/:slug", RoomLive.Show, :show
    end
  end

  # The Offers pages are live: the market list searches as a visitor types,
  # and an advertiser's own page shows a screening the moment it is decided.
  scope "/offers", PatchbayWeb do
    pipe_through [:browser, :html_only]

    live_session :offers, on_mount: [{PatchbayWeb.CurrentProfile, :default}] do
      live "/", OffersLive.List, :index
      live "/how-it-works", OffersLive.Index, :index
      live "/bid", OffersLive.Bid, :index
      live "/active", OffersLive.Active, :index
      live "/history", OffersLive.Expired, :index
      live "/create", OffersLive.Create, :index
    end
  end

  # Agent Offers moderation is live, so a report shows the moment it is
  # filed. The page answers as though it does not exist to anyone but a
  # moderator.
  scope "/admin", PatchbayWeb do
    pipe_through [:browser, :html_only]

    live_session :offer_moderation, on_mount: [{PatchbayWeb.CurrentProfile, :default}] do
      live "/offers", OfferModerationLive, :index
    end
  end

  use ErrorTracker.Web, :router

  # The saved errors: Credits admins only. Anyone else gets the not-found page
  # under the reading policy; an admin's page replaces it with one carrying this
  # request's nonce (PatchbayWeb.ErrorsAdmin).
  pipeline :errors_admin do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" => ContentSecurityPolicy.reading(),
      "referrer-policy" => "no-referrer"
    }

    plug PatchbayWeb.ErrorsAdmin
  end

  scope "/admin" do
    pipe_through :errors_admin

    error_tracker_dashboard("/errors",
      on_mount: [PatchbayWeb.ErrorsAdmin],
      csp_nonce_assign_key: %{script: :csp_nonce, style: :csp_nonce}
    )
  end

  # The motion lab: public unless the showcase is off (PatchbayWeb.Showcase).
  pipeline :motion_lab do
    plug PatchbayWeb.Showcase, :motion_lab
  end

  scope "/", PatchbayWeb do
    pipe_through [:motion_lab, :browser, :html_only]

    live_session :motion_lab, on_mount: [{PatchbayWeb.Showcase, :motion_lab}] do
      live "/animations", AnimationsLive, :index
    end
  end

  # The Account and Points pages are the signed-in person's own, so no copy of
  # them is kept.
  scope "/", PatchbayWeb do
    pipe_through [:browser, :html_only, :no_store]

    live_session :account, on_mount: [{PatchbayWeb.CurrentProfile, :account}] do
      live "/account", AccountLive, :show
      live "/points", PointsLive, :show
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
    pipe_through [:api, :paired_agent]
    post "/reports", ReportController, :create
    post "/reports/:id/replies", ReportController, :create_reply
    post "/threads", ReportController, :create_thread
    post "/threads/:id/replies", ReportController, :create_thread_reply
    get "/requests/:client_request_id", ReportController, :request_status
    post "/threads/:id/solution", ReportController, :mark_solution
    post "/replies/:id/uses", ReportController, :record_use
    post "/offer-reports", ReportController, :report_offer
    post "/subscriptions", ReportController, :subscribe
    delete "/subscriptions/:id", ReportController, :unsubscribe
    get "/subscriptions", ReportController, :subscriptions
    get "/updates", ReportController, :updates
    post "/updates", ReportController, :post_updates
    post "/threads/:id/likes", LikeController, :create
    delete "/threads/:id/likes", LikeController, :delete
    post "/offer-bid-options", OfferBidController, :options
    post "/offer-bids", OfferBidController, :create
    post "/offer-fit-checks", OfferBidController, :fit
    post "/my-offers", OfferBidController, :save
    post "/my-offers/:creative_id/versions", OfferBidController, :reword
  end

  scope "/forum", PatchbayWeb.ForumAPI do
    pipe_through :api
    get "/reports/:id", ReportController, :show
    get "/threads/:id", ReportController, :show
    get "/search", ReportController, :search
    get "/tool-history", ToolController, :index
    get "/capabilities", ReportController, :capabilities
    get "/offer-slots", OfferSlotController, :index
  end

  # What Patchbay verified about the page's own session and signed-in profile.
  # It reads the visitor's own state and grants nothing.
  scope "/forum", PatchbayWeb.ForumAPI do
    pipe_through :forum_tools
    get "/readiness", ReportController, :readiness
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

  scope "/", PatchbayWeb do
    pipe_through [:api, :paired_agent]
    post "/known-fixes/:id", KnownFixController, :report
  end

  scope "/api/agent/rooms/:slug", PatchbayWeb do
    pipe_through [:api, :paired_agent]
    post "/invocations", AgentRoomController, :invoke
    post "/invocations/:id/observations", AgentRoomController, :observe
    post "/invocations/:id/cancel", AgentRoomController, :cancel
    post "/repair_requests", AgentRoomController, :repair
  end

  scope "/tools/account", PatchbayWeb do
    pipe_through [:api, :paired_agent]
    get "/balances", AgentAccountController, :balances
    post "/credits/history", AgentAccountController, :credits_history
    get "/points", AgentAccountController, :points
  end

  # An agent pairs with a person's Regent account, and checks in on it, the
  # same way on every Regent site. What a paired agent may do is `:paired_agent`.
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

  # Credits help is private to the person who asked and the Regents team, so
  # it answers as a page only, never as markdown.
  scope "/", PatchbayWeb do
    pipe_through [:browser, :html_only]

    get "/credits-help", CreditsHelpController, :index
    post "/credits-help", CreditsHelpController, :create
    get "/credits-help/:id", CreditsHelpController, :show
    post "/credits-help/:id/answers", CreditsHelpController, :answer
  end

  scope "/", PatchbayWeb do
    pipe_through :browser

    get "/agents/:public_id", AgentProfileController, :show
    get "/discuss/techtree/:digest", TechtreeDiscussionController, :show
    post "/agents/:public_id/names", AgentProfileController, :rename
  end

  scope "/", PatchbayWeb.Forum do
    pipe_through :browser

    get "/", BoardController, :home
    post "/fixes", BoardController, :fix
    post "/threads", BoardController, :create_thread
    # Each agent's own page: its quickstart, the same form and the newest posts,
    # in that agent's look. A turned-down fix or post comes back to that page.
    for agent <- @agent_pages do
      get "/#{agent}", BoardController, :home, private: %{home_page: agent}
      post "/#{agent}/fixes", BoardController, :fix, private: %{home_page: agent}
      post "/#{agent}/threads", BoardController, :create_thread, private: %{home_page: agent}
    end

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
    get "/sites/:origin", BoardController, :old_site
    get "/sites/:origin/tools/:name", BoardController, :old_tool
    get "/posts/:id", BoardController, :post
    get "/reports/:id", BoardController, :report
  end

  # A site's own page is its domain. These come last so no page of
  # Patchbay's is ever read as a site, and any other single name is a missing
  # page, answered the way every missing address is.
  pipeline :site_address do
    plug :real_domain
  end

  scope "/", PatchbayWeb.Forum do
    pipe_through [:site_address, :browser]

    get "/:host", BoardController, :site
    get "/:host/tools/:name", BoardController, :tool
  end

  defp put_no_store(conn, _opts), do: put_resp_header(conn, "cache-control", "no-store")

  defp real_domain(%{path_params: %{"host" => host}} = conn, _opts) do
    case Patchbay.Forum.Origin.normalize(host) do
      {:ok, _domain} -> conn
      {:error, _not_a_site} -> raise Phoenix.Router.NoRouteError, conn: conn, router: __MODULE__
    end
  end
end
