defmodule TradingOptionsSim.DbBackup.Test do
  @moduledoc """
  Mock `TradingOptionsSim.DbBackup` adapter for tests — same named-`Agent`
  shape as `TradingOptionsSim.SignalBus.Test`. Never shells out to a real
  `pg_dump`.

  Default with nothing stubbed: `dump/2` returns `{:error, :not_stubbed}`
  — a test exercising the backup panel must stub the specific result it
  wants, rather than silently getting a plausible-looking default that
  could mask a real wiring bug in `SettingsLive`.
  """

  @behaviour TradingOptionsSim.DbBackup

  def start_link(_opts \\ []) do
    Agent.start_link(&initial_state/0, name: __MODULE__)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  defp initial_state, do: %{dump: {:error, :not_stubbed}}

  @doc "Stubs `dump/2`'s result."
  def stub_dump(result) do
    ensure_started()
    Agent.update(__MODULE__, &Map.put(&1, :dump, result))
  end

  @doc "Resets the stub to `{:error, :not_stubbed}`."
  def reset do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> initial_state() end)
  end

  @impl true
  def dump(_repo_config, _dir) do
    ensure_started()
    Agent.get(__MODULE__, & &1.dump)
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> Agent.start(&initial_state/0, name: __MODULE__)
      _pid -> :ok
    end
  end
end
