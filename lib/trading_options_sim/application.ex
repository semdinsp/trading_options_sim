defmodule TradingOptionsSim.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TradingOptionsSimWeb.Telemetry,
      TradingOptionsSim.Repo,
      {DNSCluster, query: Application.get_env(:trading_options_sim, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: TradingOptionsSim.PubSub},
      # Start a worker by calling: TradingOptionsSim.Worker.start_link(arg)
      # {TradingOptionsSim.Worker, arg},
      # Start to serve requests, typically the last entry
      TradingOptionsSimWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TradingOptionsSim.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TradingOptionsSimWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
