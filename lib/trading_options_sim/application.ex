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
        {Phoenix.PubSub, name: TradingOptionsSim.PubSub},
        # Per-contract monitor supervision (OPTIONS_SIM_ARCHITECTURE_PLAN.md
        # §5/§6) — Registry + DynamicSupervisor pair, mirroring trading_live's
        # MonitorRegistry/MonitorSupervisor.
        {Registry, keys: :unique, name: TradingOptionsSim.MonitorRegistry},
        {DynamicSupervisor, name: TradingOptionsSim.MonitorSupervisor, strategy: :one_for_one},
        TradingOptionsSim.PriceRelay
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

  # Skipped in :test — no real trading_hub node to connect to, and every
  # test that needs price data drives ContractMonitor/PriceRelay directly
  # rather than through a live distributed-Erlang connection (same
  # posture trading_live's own reactivator_child/0 takes for its own
  # test-only skip).
  defp hub_client_children do
    if Application.get_env(:trading_options_sim, :start_hub_client, true) do
      [
        {IbPortfolio.HubClient,
         name: TradingOptionsSim.HubClient,
         hub_node: Application.fetch_env!(:trading_options_sim, :hub_node),
         topics: ["prices:*"],
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
