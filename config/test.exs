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

# Force the MCP transport to start even though the Endpoint isn't
# actually listening under `server: false` — an MCP integration test
# dispatches straight into the plug pipeline via Plug.Test, which
# Anubis.Server.Supervisor's own "am I serving HTTP" heuristic can't see.
# Ported from trading_system's identical test override.
config :trading_options_sim, :mcp_force_start, true

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
