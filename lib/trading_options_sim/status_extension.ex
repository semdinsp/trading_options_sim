defmodule TradingOptionsSim.StatusExtension do
  @moduledoc """
  `AppStatus.Extension` implementation exposing `trading_options_sim`-specific
  health: the DB pool, and the distributed connection to `trading_hub`
  (once `TradingOptionsSim.HubMonitor` exists — see
  `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §9/§4a's build sequencing; underlying
  tick data for `ContractMonitor`'s options pricing depends on that same
  cross-node link `trading_live` already has via its own `HubMonitor`).
  Same shape as `TradingLive.StatusExtension`/`TradingSystem.StatusExtension`.

  `hub_connected?/0` is written now, ahead of `HubMonitor` itself, so this
  module's shape (and its `Process.whereis/1` guard) doesn't need to
  change later — it simply reports `false` until that process exists.

  Each check hits its own DB/GenServer round-trip independently of the
  others, so they run concurrently rather than paying their latencies
  sequentially against `AppStatus.Extension`'s fixed 2000ms call budget —
  see `TradingLive.StatusExtension`'s own moduledoc for the incident this
  guards against (a slow check taking down every other metric with it).
  """

  @behaviour AppStatus.Extension

  @checks [
    hub_connected: &__MODULE__.hub_connected?/0,
    db_pool: &__MODULE__.db_pool_stats/0
  ]

  @impl true
  def extra_metrics do
    @checks
    |> Task.async_stream(fn {key, fun} -> {key, fun.()} end,
      timeout: 1_800,
      on_timeout: :kill_task
    )
    |> Enum.zip(@checks)
    |> Map.new(fn
      {{:ok, {key, value}}, _check} -> {key, value}
      {_timeout_or_exit, {key, _fun}} -> {key, nil}
    end)
  end

  # TradingOptionsSim.HubMonitor doesn't exist yet (see this module's own
  # moduledoc) — Process.whereis/1 simply returns nil until it's built,
  # so this fails closed to `false` rather than crashing. Once HubMonitor
  # exists, wire its real connection_status()/connected? call here,
  # matching TradingLive.StatusExtension.hub_connected?/0's shape exactly.
  @doc false
  def hub_connected? do
    case Process.whereis(TradingOptionsSim.HubMonitor) do
      nil -> false
      pid -> GenServer.call(pid, :connected?)
    end
  catch
    :exit, _ -> false
  end

  @doc false
  def db_pool_stats do
    config = TradingOptionsSim.Repo.config()

    %{
      pool_size: Keyword.get(config, :pool_size),
      queue_target_ms: Keyword.get(config, :queue_target),
      queue_interval_ms: Keyword.get(config, :queue_interval),
      up?: db_up?()
    }
  end

  # See TradingLive.StatusExtension.db_up?/0's own extensive comment for
  # why the query runs inside its own try/rescue *inside* the task
  # closure (not an MFA capture) and why the timeout is bounded well
  # inside extra_metrics/0's outer Task.async_stream deadline — ported
  # verbatim, same reasoning applies unchanged.
  @db_check_timeout_ms 1200

  @doc false
  def db_up? do
    task =
      Task.async(fn ->
        try do
          TradingOptionsSim.Repo.query("SELECT 1", [], timeout: @db_check_timeout_ms)
        rescue
          error -> {:error, error}
        end
      end)

    case Task.yield(task, @db_check_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, _result}} -> true
      _ -> false
    end
  catch
    :exit, _ -> false
  end
end
