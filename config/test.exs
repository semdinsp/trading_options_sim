import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :trading_options_sim, TradingOptionsSim.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "trading_options_sim_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :trading_options_sim, TradingOptionsSimWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4008],
  secret_key_base: "9qnJdV2lPPXhLDtGysV5gErJ5j0JtBUl6CpDD3km3uWN/24Ok1yBpOlqxMITX2cu",
  server: false

# No real trading_hub node to connect to in test — every test drives
# ContractMonitor/PriceRelay directly instead. See Application.start/2's
# hub_client_child/0.
config :trading_options_sim, :start_hub_client, false

# No HubClient here, so an underlying can never tick -- waiting for one
# would burn UnderlyingSubscription's full production timeout on every
# ensure/2 and make unrelated tests time out. The refcount lifecycle the
# tests actually cover is independent of the wait.
config :trading_options_sim, :underlying_first_tick_timeout_ms, 0

# A node name that will never actually exist, so nothing connects to it
# -- but UnderlyingSubscription's :nodeup handler needs a configured
# value to compare against, otherwise the hub-restart recovery path is
# untestable and silently never exercised.
config :trading_options_sim, :hub_node, :"trading_hub@test-nonexistent"

# SimReactivator queries the Repo from application boot, before
# test_helper.exs puts Repo into sandbox :manual mode — left on, it
# grabs a connection outside any test's sandbox ownership and breaks
# other tests' checkout. Same hazard/fix as trading_live's own
# reactivate_strategies_on_boot test override.
config :trading_options_sim, :reactivate_strategies_on_boot, false

# Force the MCP transport to start even though the Endpoint isn't
# actually listening under `server: false` — an MCP integration test
# dispatches straight into the plug pipeline via Plug.Test, which
# Anubis.Server.Supervisor's own "am I serving HTTP" heuristic can't see.
# Ported from trading_system's identical test override.
config :trading_options_sim, :mcp_force_start, true

# No real trading_signal node to connect to in test — ContractMonitor
# tests drive SignalBus.Test directly (stub_topic/2) rather than a live
# distributed-Erlang connection. Same adapter-swap pattern trading_live's
# own config/test.exs uses for TradingLive.SignalBus.
config :trading_options_sim, :signal_bus_adapter, TradingOptionsSim.SignalBus.Test

# :manual — jobs are only ever run explicitly via Oban.Testing's
# perform_job/2 in a test, never by a real queue/cron plugin picking them
# up in the background. Same convention trading_system's own
# config/test.exs uses.
config :trading_options_sim, Oban, testing: :manual

# Every test seeds its own ExchangeSession/ExchangeTradingHours fixtures
# inside its own sandboxed transaction and expects ContractMonitor's
# session-open check to see them immediately — a singleton ETS cache
# populated once at application boot never would. Same bypass
# trading_live's own config/test.exs uses for its identical cache.
config :trading_options_sim, :exchange_session_cache_enabled, false

# SettingsLive's "Database Backup" panel tests stub via
# TradingOptionsSim.DbBackup.Test rather than shelling out to a real
# pg_dump. Same convention trading_system's own config/test.exs uses.
config :trading_options_sim, :db_backup_adapter, TradingOptionsSim.DbBackup.Test

# In test we don't send emails
config :trading_options_sim, TradingOptionsSim.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
