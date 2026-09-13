defmodule TradingOptionsSim.MCP.CallGuard do
  @moduledoc """
  Performance guardrail every MCP tool's `execute/2` routes through,
  since `Anubis.Server.Handlers.Tools.forward_to/4` calls `execute/2`
  synchronously in the caller's own session process — no middleware hook
  exists in the library to apply this centrally. Ported from
  `TradingSystem.MCP.CallGuard`/`TradingLive.MCP.CallGuard`, **including**
  the `TableOwner` fix documented there: a lazily-created rate-limit ETS
  table dies with the short-lived MCP session process that created it,
  so every single call sees `count: 1` and the rate limit silently never
  limits anything (confirmed live on `trading_system`, 2026-09-07 — 46
  real MCP calls, `count` logged as `1` on every one). `TableOwner` gives
  the table a permanent, supervised owner instead. See
  `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §4a for why this is carried forward
  from day one rather than re-learning that bug in a third app.

  ## `run/1`: bounded timeout

  Wraps a tool body in `Task.async/1` + `Task.yield/2` with a fixed
  timeout, so a hung downstream call can't block an MCP session
  indefinitely.

  ## `rate_limited?/2`: per-token-and-tool token bucket
  """

  require Logger

  @table __MODULE__
  @timeout_ms 5_000
  @rate_limit_window_ms 60_000
  @rate_limit_max_calls 45

  defmodule TableOwner do
    @moduledoc """
    Does nothing but own `TradingOptionsSim.MCP.CallGuard`'s rate-limit
    ETS table for the life of the application — see that module's own
    doc for why a permanent owner is required. Started once under
    `TradingOptionsSim.Application`'s supervision tree.
    """

    use GenServer

    @table TradingOptionsSim.MCP.CallGuard

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl true
    def init(_opts) do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
      {:ok, %{}}
    end
  end

  @doc """
  Runs `fun` with a #{@timeout_ms}ms budget (overridable via
  `timeout_ms`, for tests only). Returns `fun`'s own result on success,
  or `{:error, :timeout}` if the budget is exceeded.
  """
  @spec run((-> result), timeout_ms :: pos_integer()) :: result | {:error, :timeout}
        when result: term()
  def run(fun, timeout_ms \\ @timeout_ms) when is_function(fun, 0) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        Logger.warning(
          "TradingOptionsSim.MCP.CallGuard: tool call exceeded #{timeout_ms}ms, aborted"
        )

        {:error, :timeout}
    end
  end

  @doc """
  True if `identity` has made #{@rate_limit_max_calls}+ calls to
  `tool_name` within the trailing #{div(@rate_limit_window_ms, 1000)}s.
  Fixed-window, not sliding.
  """
  @spec rate_limited?(String.t(), String.t()) :: boolean()
  def rate_limited?(identity, tool_name) when is_binary(identity) and is_binary(tool_name) do
    ensure_table!()
    window = div(System.system_time(:millisecond), @rate_limit_window_ms)
    key = {identity, tool_name, window}

    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})
    count > @rate_limit_max_calls
  end

  # Defensive fallback only — TableOwner, started under
  # TradingOptionsSim.Application, is what actually keeps this table
  # alive for the life of the app. Kept only for isolated unit tests
  # that construct CallGuard calls without booting the full supervision
  # tree.
  defp ensure_table! do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    end
  catch
    :error, :badarg -> :ok
  end
end
