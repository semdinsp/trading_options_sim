defmodule TradingOptionsSim.EntryDelay do
  @moduledoc """
  Which entry delay a strategy version runs with, and how a change
  reaches its running monitors.

  The delay itself (no new entry until today's exchange open + N minutes;
  exits never delayed) is `ContractMonitor.entry_delay_elapsed?/2`. N is
  resolved here, highest first:

    1. `:override` -- the operator setting `StrategyVersion.entry_delay_minutes`,
       changeable on a running strategy. `nil` means no override.
    2. `:version` -- the version's frozen `params["entry_delay_minutes"]`.
    3. `:default` -- `config :trading_options_sim, :default_entry_delay_minutes`.
       This app has no runtime settings store, so the default is changed
       in config and takes a restart.

  Mirrors trading_live's `StrategyStockMonitor.broadcast_entry_delay_minutes/2`:
  a change is broadcast on this app's own `TradingOptionsSim.PubSub`, and
  each monitor subscribed to its version's topic swaps the value in
  place, so no restart or reactivation is needed. The EFFECTIVE value is
  broadcast, so clearing an override falls back to the version or the
  default live too.

  `effective/1` is also what the promotion export ships, so trading_live
  copies the delay the strategy actually traded with.
  """

  alias TradingOptionsSim.Sim.StrategyVersion

  @type source :: :override | :version | :default

  @doc "The effective entry delay in minutes and which layer it came from."
  @spec effective(StrategyVersion.t() | map()) :: {non_neg_integer(), source()}
  def effective(%{entry_delay_minutes: minutes}) when is_integer(minutes) and minutes >= 0,
    do: {minutes, :override}

  def effective(%{params: %{"entry_delay_minutes" => minutes}})
      when is_integer(minutes) and minutes >= 0,
      do: {minutes, :version}

  def effective(_version), do: {default_minutes(), :default}

  @doc "The effective entry delay in minutes (see `effective/1`)."
  @spec minutes(StrategyVersion.t() | map()) :: non_neg_integer()
  def minutes(version), do: version |> effective() |> elem(0)

  @doc "The app-wide default from config (`:default_entry_delay_minutes`)."
  @spec default_minutes() :: non_neg_integer()
  def default_minutes,
    do: Application.get_env(:trading_options_sim, :default_entry_delay_minutes, 0)

  @doc "The topic a version's monitors listen on for entry delay changes."
  @spec topic(String.t()) :: String.t()
  def topic(strategy_version_id),
    do: "strategy_version:#{strategy_version_id}:entry_delay_minutes"

  @doc """
  Tells `version`'s running monitors its effective entry delay, as
  `{:entry_delay_minutes_updated, minutes}` on `topic/1`.
  """
  @spec broadcast(StrategyVersion.t()) :: :ok | {:error, term()}
  def broadcast(%StrategyVersion{id: id} = version) do
    Phoenix.PubSub.broadcast(
      TradingOptionsSim.PubSub,
      topic(id),
      {:entry_delay_minutes_updated, minutes(version)}
    )
  end
end
