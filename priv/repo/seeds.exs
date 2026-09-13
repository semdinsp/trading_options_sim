# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# One-time seed of exchange_trading_hours/exchange_sessions — see
# OPTIONS_SIM_ARCHITECTURE_PLAN.md §5c. v1 is US-only (this app has no
# non-US target pool members today); a second session can be added later
# with zero code change, same as trading_live's Asia session. Safe to
# re-run: every insert is idempotent on the unique `name`/`exchange`
# constraint via Repo.insert/2's on_conflict.

alias TradingOptionsSim.Repo
alias TradingOptionsSim.Sim.{ExchangeTradingHours, ExchangeSession}

sessions = [
  %{
    name: "US",
    timezone: "America/New_York",
    start_time: ~T[09:30:00],
    end_time: ~T[16:00:00],
    enabled: true,
    days_of_week: [1, 2, 3, 4, 5],
    close_before_minutes: 11,
    market: "US_EQUITIES"
  }
]

hours_by_name =
  for attrs <- sessions, into: %{} do
    {:ok, row} =
      %ExchangeTradingHours{}
      |> ExchangeTradingHours.changeset(attrs)
      |> Repo.insert(
        on_conflict:
          {:replace,
           [:timezone, :start_time, :end_time, :enabled, :days_of_week, :close_before_minutes]},
        conflict_target: :name,
        returning: true
      )

    {row.name, row}
  end

# SMART = IBKR's smart-order-routing pseudo-exchange, same mapping
# trading_system/trading_live already use for US symbols.
exchange_mappings = %{
  "NYSE" => "US",
  "NASDAQ" => "US",
  "SMART" => "US",
  "ARCA" => "US"
}

for {exchange, session_name} <- exchange_mappings do
  hours = Map.fetch!(hours_by_name, session_name)

  {:ok, _row} =
    %ExchangeSession{}
    |> ExchangeSession.changeset(%{
      exchange: exchange,
      exchange_trading_hours_id: hours.id
    })
    |> Repo.insert(
      on_conflict: {:replace, [:exchange_trading_hours_id]},
      conflict_target: :exchange
    )
end

IO.puts(
  "Seeded #{map_size(hours_by_name)} exchange_trading_hours and #{map_size(exchange_mappings)} exchange_sessions."
)
