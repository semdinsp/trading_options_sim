defmodule TradingOptionsSim.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        TradingOptionsSimWeb.Telemetry,
        TradingOptionsSim.Repo,
        {DNSCluster,
         query: Application.get_env(:trading_options_sim, :dns_cluster_query) || :ignore},
        {Oban, Application.fetch_env!(:trading_options_sim, Oban)},
        {Phoenix.PubSub, name: TradingOptionsSim.PubSub},
        # Local same-named Phoenix.PubSub server for trading_hub's own
        # PubSub instance — required for IbPortfolio.HubClient's
        # Phoenix.PubSub.subscribe/2 call (inside hub_client_children/0
        # below) against TradingHub.PubSub to receive anything at all.
        # Phoenix.PubSub's default PG2 adapter propagates broadcasts
        # between *same-named* PubSub servers on different
        # distributed-Erlang nodes via :pg — but only once a same-named
        # local server exists to join that group in the first place.
        # Without this, every subscribe raises `ArgumentError: unknown
        # registry: TradingHub.PubSub`, unconditionally, regardless of
        # node connectivity (confirmed live 2026-09-13 running this app
        # with `iex --name ... -S mix phx.server`) — trading_live's own
        # application.ex has the identical child (with the identical
        # comment/incident) for the exact same reason; see that file for
        # the fuller "what actually happens without this" writeup.
        Supervisor.child_spec({Phoenix.PubSub, name: TradingHub.PubSub}, id: :trading_hub_pubsub),
        # Same cross-node PubSub pattern as TradingHub.PubSub just above,
        # new target app — required for TradingOptionsSim.SignalConnection's
        # ContractMonitor callers to Phoenix.PubSub.subscribe/2 against a
        # resolved trading_signal topic and actually receive values. See
        # SignalConnection's own moduledoc (ported from
        # TradingLive.SignalConnection) for the full erpc/subscribe split.
        Supervisor.child_spec({Phoenix.PubSub, name: TradingSignal.PubSub},
          id: :trading_signal_pubsub
        ),
        # Per-contract monitor supervision (OPTIONS_SIM_ARCHITECTURE_PLAN.md
        # §5/§6) — Registry + DynamicSupervisor pair, mirroring trading_live's
        # MonitorRegistry/MonitorSupervisor.
        {Registry, keys: :unique, name: TradingOptionsSim.MonitorRegistry},
        # max_restarts/max_seconds raised well above DynamicSupervisor's
        # own default (3 restarts in 5 seconds) — at the default, a burst
        # of ContractMonitor crashes (e.g. a bad tick shared across every
        # monitor watching the same underlying) would exceed the
        # supervisor's own restart intensity, terminate it, and come back
        # from TradingOptionsSim.Supervisor with zero children — nothing
        # re-populates a DynamicSupervisor's dynamically-started children
        # after its own restart except TradingOptionsSim.SimReactivator's
        # :DOWN handler (see that module's own moduledoc), which only
        # exists because trading_live hit exactly this failure mode live
        # and fixed it the identical way (confirmed by reading that
        # module directly).
        {DynamicSupervisor,
         name: TradingOptionsSim.MonitorSupervisor,
         strategy: :one_for_one,
         max_restarts: 100,
         max_seconds: 10},
        TradingOptionsSim.PriceRelay,
        TradingOptionsSim.SignalConnection,
        # Exchange-hours support (OPTIONS_SIM_ARCHITECTURE_PLAN.md §5c) —
        # ExchangeSessionCache backs every ContractMonitor's session-open
        # check, EodCloser force-closes open positions near session
        # close. Ported near-verbatim from trading_live's identical pair.
        TradingOptionsSim.ExchangeSessionCache,
        TradingOptionsSim.EodCloser
      ] ++
        reactivator_child() ++
        [
          # MCP write-tool rate-limit table — see CallGuard.TableOwner's own
          # moduledoc for why this must be a permanent supervised owner,
          # not a lazily-created ETS table inside a short-lived MCP
          # session process.
          TradingOptionsSim.MCP.CallGuard.TableOwner,
          # Binds no port of its own: :streamable_http here only registers a
          # named transport process the Plug mounted at `/mcp` in
          # TradingOptionsSimWeb.Router talks to, riding on the main
          # Endpoint below. `start:` left unset in dev/prod —
          # Anubis.Server.Supervisor's own should_start?/1 defers to
          # Phoenix's "am I actually serving HTTP" signal, matching
          # config/test.exs's Endpoint `server: false`. config/test.exs
          # overrides this to `true` via :trading_options_sim,
          # :mcp_force_start specifically so an MCP integration test can
          # exercise the real `/mcp` HTTP transport (Plug.Test dispatches
          # straight into the plug pipeline without a listening socket, so
          # Anubis's own heuristic would otherwise leave it off there) —
          # ported from trading_system's identical setup.
          {TradingOptionsSim.MCP.Server,
           transport:
             {:streamable_http,
              start: Application.get_env(:trading_options_sim, :mcp_force_start)}}
        ] ++
        hub_client_children() ++
        [
          # Start to serve requests, typically the last entry
          TradingOptionsSimWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TradingOptionsSim.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Skipped in :test — SimReactivator queries the Repo from application
  # boot, before test_helper.exs puts Repo into sandbox :manual mode, so
  # left on it grabs a connection outside any test's sandbox ownership
  # and breaks other tests' checkout — identical hazard and identical
  # fix as trading_live's own reactivate_strategies_on_boot flag
  # (confirmed by reading that module's config/test.exs directly).
  defp reactivator_child do
    if Application.get_env(:trading_options_sim, :reactivate_strategies_on_boot, true) do
      [TradingOptionsSim.SimReactivator]
    else
      []
    end
  end

  # Skipped in :test — no real trading_hub node to connect to, and every
  # test that needs price data drives ContractMonitor/PriceRelay directly
  # rather than through a live distributed-Erlang connection (same
  # posture trading_live's own reactivator_child/0 takes for its own
  # test-only skip).
  #
  # Subscribes to trading_hub's fan-out topic by its contract name
  # rather than the "prices:*" wildcard this used to pass. Phoenix.PubSub
  # has no wildcard subscriptions -- IbPortfolio.HubClient was expanding
  # the pattern through a private lookup table to "prices:all" before
  # subscribing, so naming that topic directly is the same subscription,
  # just compile-checked against TradingContract instead of matching a
  # string literal the hub could rename out from under us.
  defp hub_client_children do
    if Application.get_env(:trading_options_sim, :start_hub_client, true) do
      [
        {IbPortfolio.HubClient,
         name: TradingOptionsSim.HubClient,
         hub_node: Application.fetch_env!(:trading_options_sim, :hub_node),
         topics: [TradingContract.Topics.prices_all()],
         forward_to: TradingOptionsSim.PriceRelay}
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TradingOptionsSimWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
