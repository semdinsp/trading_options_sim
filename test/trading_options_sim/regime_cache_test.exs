defmodule TradingOptionsSim.RegimeCacheTest do
  # async: false -- the cache is one global :persistent_term.
  use ExUnit.Case, async: false

  alias TradingOptionsSim.RegimeCache

  setup do
    RegimeCache.put(nil)
    on_exit(fn -> RegimeCache.put(nil) end)
  end

  test "maps each axis with TradingCore.Regime's -1/0/1 ordinals, as trading_live does" do
    assert RegimeCache.snapshot_values(%{trend_state: :down, vol_state: :stressed}) ==
             %{"regime_trend_ordinal" => -1, "regime_vol_ordinal" => 1}

    assert RegimeCache.snapshot_values(%{trend_state: :chop, vol_state: :calm}) ==
             %{"regime_trend_ordinal" => 0, "regime_vol_ordinal" => -1}

    # A seed may carry strings.
    assert RegimeCache.snapshot_values(%{trend_state: "up", vol_state: "normal"}) ==
             %{"regime_trend_ordinal" => 1, "regime_vol_ordinal" => 0}
  end

  # Fails closed: an unclassified or unknown axis is left out, never 0.
  test "leaves out a missing or unrecognised axis" do
    assert RegimeCache.snapshot_values(nil) == %{}

    assert RegimeCache.snapshot_values(%{trend_state: nil, vol_state: :calm}) ==
             %{"regime_vol_ordinal" => -1}

    assert RegimeCache.snapshot_values(%{trend_state: :sideways, vol_state: "wild"}) == %{}
  end

  test "caches a regime_label broadcast from trading_signal" do
    Phoenix.PubSub.broadcast(
      TradingSignal.PubSub,
      "regime:label",
      {:regime_label, %{label: "normal|down", trend_state: :down, vol_state: :normal}}
    )

    # A call after the broadcast proves the cache has handled it.
    _ = :sys.get_state(RegimeCache)
    assert %{label: "normal|down"} = RegimeCache.current()
  end

  test "normalise_seed keeps the broadcast keys and renames label_changed_at" do
    at = ~U[2026-09-28 14:00:00Z]

    assert RegimeCache.normalise_seed(%{
             label: "calm|up",
             trend_state: :up,
             vol_state: :calm,
             label_changed_at: at,
             vix_definition_spec: :internal
           }) == %{label: "calm|up", trend_state: :up, vol_state: :calm, changed_at: at}
  end
end
