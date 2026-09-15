# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :trading_options_sim,
  ecto_repos: [TradingOptionsSim.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Single queue/worker for now (§2's QuarantineEligibilityWorker) — more
# are added incrementally as needed, matching trading_system's own
# config.exs comment for its (much larger) Oban setup.
config :trading_options_sim, Oban,
  repo: TradingOptionsSim.Repo,
  queues: [daily_rollups: 1],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       # 07:00 UTC — after the US trading day has fully closed (~3am ET),
       # so "yesterday" (this worker's default trading_date) is a
       # complete, closed trading day by the time this runs. Same slot
       # trading_system's own QuarantineEligibilityWorker uses, same
       # reasoning (see that worker's moduledoc for the 2026-07-31
       # incident this timing avoids: checking Date.utc_today() at
       # 07:00 UTC finds a day that hasn't traded yet).
       {"0 7 * * *", TradingOptionsSim.Sim.Workers.QuarantineEligibilityWorker},
       # 21:00 UTC — 1 hour after the US options market's 4pm ET close
       # during EDT (drifts to 5pm ET during EST — a fixed UTC time, not
       # derived from any ExchangeSession, same simplicity trade-off
       # QuarantineEligibilityWorker's own fixed 07:00 UTC slot makes).
       # Deliberately a separate slot from the 07:00 UTC one above, not
       # stacked with it — see PerformanceSnapshotWorker's own moduledoc
       # for why "shortly after today's close" and "after yesterday's
       # day is fully done" are different timing requirements.
       {"0 21 * * *", TradingOptionsSim.Sim.Workers.PerformanceSnapshotWorker}
     ]},
    {Oban.Plugins.Pruner, max_age: 8 * 24 * 60 * 60}
  ]

# app_status shared library — standard /status (JSON) and /status/metrics
# (Prometheus) endpoints for this app, matching trading_hub/trading_live/
# trading_system's own integration. See app_status's README for the full
# contract; TradingOptionsSim.StatusExtension supplies app-specific
# health (DB pool, trading_hub connectivity — see that module's doc).
config :app_status,
  app_name: :trading_options_sim,
  endpoint: TradingOptionsSimWeb.Endpoint,
  extension: TradingOptionsSim.StatusExtension

# Configure the endpoint
config :trading_options_sim, TradingOptionsSimWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TradingOptionsSimWeb.ErrorHTML, json: TradingOptionsSimWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: TradingOptionsSim.PubSub,
  live_view: [signing_salt: "q4Gas8Nw"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :trading_options_sim, TradingOptionsSim.Mailer, adapter: Swoosh.Adapters.Local

# Elixir's built-in Calendar.UTCOnlyTimeZoneDatabase only resolves "Etc/UTC"
# — any other zone raises/returns {:error, :utc_only_time_zone_database}.
# TradingCore.MarketHours.open?/2 (used by ContractMonitor's own
# session_open?/1 exchange-hours gate) calls DateTime.shift_zone/2 against
# each ExchangeSession's real IANA tz (e.g. "America/New_York" for NASDAQ/
# ARCA) — without a real tz database, every price tick that reaches
# maybe_transition/2 for a member with a non-nil :exchange crashes this
# GenServer outright (confirmed live 2026-09-15: two activated SPY option
# strategies died within seconds of their first real tick, silently
# leaving their SimRun stuck "open" in the DB with no running monitor —
# see trading_system/trading_live's own identical fix and incident notes
# for the same root cause in their own config.exs).
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

# tzdata polls tzdata.services.spacetime.dev for release updates by default
# — a background updater racing its own ETS release swap against a
# concurrent lookup is a known source of transient
# {:error, :time_zone_not_found} failures even for a zone that
# unquestionably exists. Disabled — matches trading_system/trading_live's
# own precedent of updating tz data via `mix deps.update tzdata` (a
# deliberate, tested step) rather than a live network poll at runtime.
config :tzdata, :autoupdate, :disabled

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  trading_options_sim: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  trading_options_sim: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
