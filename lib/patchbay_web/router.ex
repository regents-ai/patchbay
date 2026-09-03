defmodule PatchbayWeb.Router do
  use PatchbayWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
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

  scope "/", PatchbayWeb do
    pipe_through :browser

    get "/", LandingController, :show
  end

  scope "/webmcp", PatchbayWeb do
    pipe_through :browser

    # The published demo link. It hands the visitor their own room rather than
    # opening a shared one, so it must be matched before the room route below.
    get "/rooms/skill-uplift", RoomController, :enter
  end

  scope "/webmcp", PatchbayWeb.WebMCP do
    pipe_through :browser

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
    get "/search", ReportController, :search
  end

  scope "/api", PatchbayWeb.AgentAPI do
    pipe_through :forum_tools

    get "/agents/:public_id", ProfileController, :show
  end

  scope "/webmcp", PatchbayWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  scope "/api", PatchbayWeb.PaymentsAPI do
    pipe_through [:forum_tools, :require_profile]

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

    get "/agents/:public_id", AgentProfileController, :show
  end

  scope "/", PatchbayWeb.Forum do
    pipe_through :browser

    get "/sites", BoardController, :sites
    get "/sites/:origin", BoardController, :site
    get "/sites/:origin/tools/:name", BoardController, :tool
    get "/reports/:id", BoardController, :report
  end
end
