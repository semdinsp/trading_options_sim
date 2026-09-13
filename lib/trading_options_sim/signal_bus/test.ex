defmodule TradingOptionsSim.SignalBus.Test do
  @moduledoc """
  Mock `TradingOptionsSim.SignalBus` adapter for tests. Backed by a named
  `Agent`, mirroring `TradingLive.SignalBus.Test`'s exact shape, so test
  processes can stub which topic a signal name resolves to (simulating
  `TradingSignal.Signals.request/1`'s slug -> canonical-topic resolution)
  without needing a live `trading_signal` node.

  Defaults with nothing stubbed: `request/1` returns `{:ok, "signals:" <>
  name}` — i.e. behaves as if the name were already its own canonical
  topic, which is what most tests want (no distinction to exercise). Call
  `stub_topic/2` when a test specifically needs to exercise the
  slug/canonical-name distinction (a resolved topic different from the
  requested name).
  """

  @behaviour TradingOptionsSim.SignalBus

  def start_link(_opts \\ []) do
    Agent.start_link(&initial_state/0, name: __MODULE__)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  defp initial_state, do: %{topics: %{}, requested_names: []}

  @doc "Stubs the topic returned for `name` by `request/1`."
  def stub_topic(name, topic) do
    ensure_started()
    Agent.update(__MODULE__, &put_in(&1, [:topics, name], topic))
  end

  @doc "Resets all stubs to their defaults."
  def reset do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> initial_state() end)
  end

  @doc """
  Every name `request/1` has been called with since the last `reset/0` —
  lets a test assert a name was (or, more usefully, was never) requested
  as a real `SignalBus` catalog signal.
  """
  def requested_names do
    ensure_started()
    Agent.get(__MODULE__, & &1.requested_names)
  end

  @impl true
  def request(name) do
    ensure_started()
    Agent.update(__MODULE__, &Map.update!(&1, :requested_names, fn names -> [name | names] end))
    topic = Agent.get(__MODULE__, &get_in(&1, [:topics, name])) || "signals:" <> name
    {:ok, topic}
  end

  # Same reasoning as TradingLive.SignalBus.Test.ensure_started/0:
  # Agent.start/2 (not start_link/2) so this cross-test singleton isn't
  # accidentally linked to (and killed by) whichever test process happens
  # to start it first.
  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> Agent.start(&initial_state/0, name: __MODULE__)
      _pid -> :ok
    end
  end
end
