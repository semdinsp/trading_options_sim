defmodule TradingOptionsSimWeb.Router do
  use TradingOptionsSimWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TradingOptionsSimWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", TradingOptionsSimWeb do
    pipe_through :browser

    # Active Strategies is the primary operator-facing screen (what's
    # running right now), so it doubles as the home page rather than
    # leaving "/" on the unrelated Phoenix generator splash page.
    live "/", ActiveStrategiesLive
    live "/settings", SettingsLive
    live "/runs", RunsLive
    live "/active_strategies", ActiveStrategiesLive
    live "/strategy_versions", StrategyVersionsLive
    live "/strategy_versions/:id", StrategyVersionDetailLive
    live "/system-performance", SystemPerformanceLive
  end

  # Unauthenticated by design (scraper/uptime-check friendly) — see
  # app_status's own README "Security" section for the production
  # hardening options (network restriction, shared-secret header, basic
  # auth) before exposing this publicly.
  forward "/status", AppStatus.Plug

  scope "/api/v1", TradingOptionsSimWeb.Api do
    pipe_through :api

    get "/strategies", StrategyController, :index
    get "/strategies/:id", StrategyController, :show
    post "/strategies", StrategyController, :create
    post "/strategies/:id/versions", StrategyController, :create_version

    get "/versions", StrategyVersionController, :index
    get "/versions/:id", StrategyVersionController, :show
    post "/versions/:id/promote", StrategyVersionController, :promote
    post "/versions/:id/downgrade", StrategyVersionController, :downgrade
    post "/versions/:id/activate", StrategyVersionController, :activate
    post "/versions/:id/deactivate", StrategyVersionController, :deactivate
    post "/versions/:id/link_live_strategy", StrategyVersionController, :link_live_strategy
    post "/versions/:id/unlink_live_strategy", StrategyVersionController, :unlink_live_strategy
    put "/versions/:id/tags", StrategyVersionController, :put_tags
    post "/versions/:id/tags", StrategyVersionController, :add_tag
    delete "/versions/:id/tags/:tag_id", StrategyVersionController, :remove_tag

    get "/runs", RunController, :index
    get "/runs/:id", RunController, :show

    get "/target_pools", TargetPoolController, :index
    get "/target_pools/:id", TargetPoolController, :show
    post "/target_pools", TargetPoolController, :create
    post "/target_pools/:id/members", TargetPoolController, :create_member

    get "/tags", TagController, :index
  end

  # MCP server — bare forward (auth is per-tool `scopes:`, not a
  # router-level plug), matching trading_system's own mounting.
  forward "/mcp", Anubis.Server.Transport.StreamableHTTP.Plug,
    server: TradingOptionsSim.MCP.Server

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:trading_options_sim, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TradingOptionsSimWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
