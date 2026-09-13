defmodule TradingOptionsSim.Repo do
  use Ecto.Repo,
    otp_app: :trading_options_sim,
    adapter: Ecto.Adapters.Postgres
end
