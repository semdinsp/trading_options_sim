defmodule TradingOptionsSim.OccSymbol do
  @moduledoc """
  Builds the OCC-style local symbol string IBKR/`trading_hub` uses to
  identify one specific option contract on the wire — e.g. `SPY` at a
  $762.00 strike, call, expiring 2026-11-20 becomes
  `"SPY   261120C00762000"`.

  This is the missing half of `TradingOptionsSim.ContractMonitor`'s own
  `:ibkr_live` pricing backend: that module has always required an
  `:occ_symbol` to subscribe to trading_hub's per-contract
  `TickOptionComputation` broadcast (see its own moduledoc), but nothing
  in this app computed one — `SimActivator.activate/1` only ever starts
  monitors on the default `:black_scholes` (theoretical/modeled price)
  backend, never `:ibkr_live` (real market price). This module exists
  so that gap can be closed without guessing the format.

  ## Format, verified against `trading_hub`'s own code

  `TradingHub.IBKR.Subscriptions.send_req_mkt_data/3`'s own comment
  documents a real OCC local_symbol example verbatim:
  `"AAPL  250117C00150000"` — the standard 21-character OCC option
  symbol:

    * underlying symbol, left-justified, padded with spaces to 6
      characters (`"AAPL  "`, `"SPY   "`)
    * expiry as `YYMMDD` (2-digit year — NOT the `YYYYMMDD` wire format
      `TradingOptionsSim.Sim.SimRun`/`ContractMonitor.contract_key`
      themselves use internally)
    * right: `"C"` or `"P"`
    * strike as cents-of-a-dollar-times-10 (i.e. dollars × 1000),
      zero-padded to 8 digits (`$150.00` → `150000` → `"00150000"`)

  This module never talks to IBKR/`trading_hub` itself — it's pure
  string construction from data this app already has (a `SimRun`'s or
  `ContractMonitor.contract_key/0`'s own `symbol`/`expiry`/`strike`/
  `right`), so it can be unit-tested without any live connection.
  """

  @doc """
  Builds the OCC local symbol for one contract. `symbol` is the bare
  underlying ticker (`"SPY"`, not already padded); `expiry` is this
  app's own `"YYYYMMDD"` wire format (matches `SimRun.expiry`/
  `ContractMonitor.contract_key`'s own convention — converted to OCC's
  `YYMMDD` internally); `strike` is a `Decimal`; `right` is `"C"` or
  `"P"`.

      iex> TradingOptionsSim.OccSymbol.build("SPY", "20261120", Decimal.new("762.00"), "C")
      "SPY   261120C00762000"

      iex> TradingOptionsSim.OccSymbol.build("AAPL", "20250117", Decimal.new("150.00"), "C")
      "AAPL  250117C00150000"
  """
  @spec build(String.t(), String.t(), Decimal.t(), String.t()) :: String.t()
  def build(symbol, expiry, strike, right)
      when is_binary(symbol) and is_binary(expiry) and right in ["C", "P"] do
    String.pad_trailing(symbol, 6) <>
      occ_date(expiry) <>
      right <>
      occ_strike(strike)
  end

  # "YYYYMMDD" (this app's own wire format) -> OCC's "YYMMDD" — drops
  # the century digits, exactly as IBKR's own local_symbol convention
  # does (see moduledoc's verified example: "250117", not "20250117").
  defp occ_date(<<_century::binary-size(2), yy_mm_dd::binary-size(6)>>), do: yy_mm_dd

  # Strike encoded as dollars * 1000, zero-padded to 8 digits — e.g.
  # $762.00 -> 762000 -> "00762000". Decimal.mult/2 then Decimal.round/2
  # (not Decimal.to_integer/1 directly) so a strike carrying fractional
  # cents (e.g. an unusual $150.005 weekly strike) rounds the way IBKR's
  # own encoding does rather than truncating silently.
  defp occ_strike(strike) do
    strike
    |> Decimal.mult(1000)
    |> Decimal.round(0)
    |> Decimal.to_integer()
    |> Integer.to_string()
    |> String.pad_leading(8, "0")
  end
end
