defmodule TradingOptionsSim.RegimeCache do
  @moduledoc """
  Local cache of `trading_signal`'s session regime label, so rules can use
  `"regime_trend_ordinal"` and `"regime_vol_ordinal"`: the same two
  pseudo-signals, names and `-1`/`0`/`1` mapping as trading_live's
  `StrategyStockMonitor` and trading_system (`TradingCore.Regime.ordinal/1`):

    * trend: `-1` down, `0` chop, `1` up
    * vol:   `-1` calm, `0` normal, `1` stressed

  so a promoted rule means the same thing in both apps. Ported from
  `TradingLive.RegimeCache`:

    * Subscribes to `"regime:label"` on `TradingSignal.PubSub`
      (`{:regime_label, payload}`, broadcast by
      `TradingSignal.Regime.SessionLabel` only when the label changes).
    * On every `:trading_signal_connected` (including the first connect)
      it re-subscribes (once) and seeds from `SessionLabel.current/0`,
      because a label that doesn't change after a restart is never
      re-broadcast.

  Unlike trading_live's, `current/0` reads a `:persistent_term`, not the
  GenServer: every `ContractMonitor` reads it on every evaluation, and the
  label changes at most every 30 minutes, so a rare global write buys a
  lock-free read. `nil` until a payload arrives, which leaves the regime
  keys out of the snapshot so a rule on them fails closed.
  """

  use GenServer

  alias TradingOptionsSim.SignalConnection

  @topic "regime:label"
  @key {__MODULE__, :payload}

  # SessionLabel.broadcast_label/1's payload keys. SessionLabel.current/0
  # returns its whole state instead; normalise_seed/1 maps it onto these.
  @broadcast_keys [
    :label,
    :vol_state,
    :vol_state_percentile,
    :trend_state,
    :vix_level,
    :spy_price,
    :spy_sma_20,
    :spy_slope_20,
    # Freshness (trading_signal #191): when the label was last
    # confirmed and for which exchange session. MarketContext uses
    # session_date to drop a previous session's label.
    :evaluated_at,
    :session_date
  ]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The last regime payload received, or `nil`. Never blocks."
  @spec current() :: map() | nil
  def current, do: :persistent_term.get(@key, nil)

  @doc """
  The rule snapshot keys for `payload`: `"regime_trend_ordinal"` and
  `"regime_vol_ordinal"`, each only when its axis is classified.
  """
  @spec snapshot_values(map() | nil) :: map()
  def snapshot_values(nil), do: %{}

  def snapshot_values(payload) when is_map(payload) do
    [
      {"regime_trend_ordinal", Map.get(payload, :trend_state)},
      {"regime_vol_ordinal", Map.get(payload, :vol_state)}
    ]
    |> Enum.flat_map(fn {key, axis} ->
      case ordinal(axis) do
        nil -> []
        value -> [{key, value}]
      end
    end)
    |> Map.new()
  end

  @doc "The snapshot keys this module can write."
  def snapshot_keys, do: ~w(regime_trend_ordinal regime_vol_ordinal)

  @doc false
  # Test-only: set or clear the cached payload.
  def put(payload) do
    if payload, do: :persistent_term.put(@key, payload), else: :persistent_term.erase(@key)
    :ok
  end

  # Axes arrive as atoms from a broadcast and may arrive as strings from
  # a seed; an unrecognised value is left out rather than guessed.
  @axis_values ~w(calm normal stressed down chop up)a
  defp ordinal(axis) when axis in @axis_values, do: TradingCore.Regime.ordinal(axis)

  defp ordinal(axis) when is_binary(axis) do
    case Enum.find(@axis_values, &(Atom.to_string(&1) == axis)) do
      nil -> nil
      atom -> TradingCore.Regime.ordinal(atom)
    end
  end

  defp ordinal(_axis), do: nil

  @doc false
  # SessionLabel.current/0 returns its GenServer state, not the broadcast
  # payload; keep only the broadcast keys (see TradingLive.RegimeCache).
  def normalise_seed(current) when is_map(current) do
    current
    |> Map.take(@broadcast_keys)
    |> Map.put(:changed_at, Map.get(current, :label_changed_at, Map.get(current, :changed_at)))
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(TradingOptionsSim.PubSub, "trading_signal:connected")
    subscribe_once()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:trading_signal_connected, state) do
    subscribe_once()
    seed()
    {:noreply, state}
  end

  def handle_info({:regime_label, payload}, state) when is_map(payload) do
    put(payload)
    {:noreply, state}
  end

  # An evaluation that left the label unchanged: refresh evaluated_at
  # and session_date (and the label, should a change have been missed),
  # keeping the rest of the last full payload. Without this, the cache
  # only ever saw label CHANGES, so session_date stayed on whatever day
  # the label last changed and MarketContext dropped today's regime.
  def handle_info({:regime_heartbeat, beat}, state) when is_map(beat) do
    put(Map.merge(current() || %{}, Map.take(beat, [:label, :evaluated_at, :session_date])))
    {:noreply, state}
  end

  # {:regime_raw, _} also arrives on this topic on every VIX/SPY tick;
  # the label is what rules use.
  def handle_info(_other, state), do: {:noreply, state}

  defp subscribe_once do
    unless @topic in Registry.keys(TradingSignal.PubSub, self()) do
      Phoenix.PubSub.subscribe(TradingSignal.PubSub, @topic)
    end
  end

  # Best effort: on failure the cached payload is left as it is.
  defp seed do
    case SignalConnection.current_regime() do
      {:ok, current} when is_map(current) -> put(normalise_seed(current))
      _ -> :ok
    end
  catch
    :exit, _reason -> :ok
  end
end
