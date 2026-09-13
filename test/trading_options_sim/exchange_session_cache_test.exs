defmodule TradingOptionsSim.ExchangeSessionCacheTest do
  use TradingOptionsSim.DataCase, async: true

  alias TradingOptionsSim.ExchangeSessionCache
  alias TradingOptionsSim.Sim.{ExchangeSession, ExchangeTradingHours}

  defp exchange_fixture do
    exchange = "CACHE_TEST_#{System.unique_integer([:positive])}"

    {:ok, hours} =
      %ExchangeTradingHours{}
      |> ExchangeTradingHours.changeset(%{
        name: exchange,
        timezone: "America/New_York",
        start_time: ~T[09:30:00],
        end_time: ~T[16:00:00],
        days_of_week: [1, 2, 3, 4, 5]
      })
      |> Repo.insert()

    {:ok, _session} =
      %ExchangeSession{}
      |> ExchangeSession.changeset(%{exchange: exchange, exchange_trading_hours_id: hours.id})
      |> Repo.insert()

    exchange
  end

  test "returns a Session struct for a mapped exchange" do
    exchange = exchange_fixture()

    assert %TradingCore.MarketHours.Session{timezone: "America/New_York"} =
             ExchangeSessionCache.fetch(exchange)
  end

  test "returns nil for an unmapped exchange" do
    assert ExchangeSessionCache.fetch("NEVER_MAPPED") == nil
  end

  # :exchange_session_cache_enabled is false in :test (config/test.exs)
  # — fetch/1 always queries the DB directly, so a row created after a
  # previous fetch is seen immediately, with no cache to refresh.
  test "sees a freshly-inserted row immediately (cache bypassed in :test)" do
    assert ExchangeSessionCache.fetch("NOT_YET_MAPPED") == nil

    exchange_id = "NOT_YET_MAPPED"

    {:ok, hours} =
      %ExchangeTradingHours{}
      |> ExchangeTradingHours.changeset(%{
        name: "CACHE_TEST_late_#{System.unique_integer([:positive])}",
        timezone: "Etc/UTC",
        start_time: ~T[00:00:00],
        end_time: ~T[23:59:59],
        days_of_week: [1, 2, 3, 4, 5]
      })
      |> Repo.insert()

    {:ok, _session} =
      %ExchangeSession{}
      |> ExchangeSession.changeset(%{
        exchange: exchange_id,
        exchange_trading_hours_id: hours.id
      })
      |> Repo.insert()

    assert %TradingCore.MarketHours.Session{} = ExchangeSessionCache.fetch(exchange_id)
  end
end
