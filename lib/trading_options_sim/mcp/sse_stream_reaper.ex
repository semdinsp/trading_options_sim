defmodule TradingOptionsSim.MCP.SseStreamReaper do
  @moduledoc """
  Ends anubis_mcp SSE stream processes whose client has gone. Ported from
  trading_live (its PR #273).

  anubis_mcp 2.0.0's `Anubis.SSE.Streaming.loop/5` only notices a gone
  client when a write fails, and its only periodic write is the
  keepalive. `Anubis.Server.Transport.StreamableHTTP` sends
  `:sse_keepalive` only to the one stream per session in its
  `sse_handlers` map, so when a client opens a new stream for the same
  session, the old one never writes again, never exits, and holds its
  socket forever. On 2026-09-29 trading_live accumulated 170 such streams
  in ~14 hours, hit macOS's 256 open-file limit (`emfile`), and lost its
  code reloader and module loading. This app runs the same anubis_mcp
  version (0 leaked streams at the time, since it sees little MCP use).

  Every 30 seconds this sends every process parked in that loop the same
  `:sse_keepalive` the transport sends. For a gone client the write
  fails on the first or second nudge, the loop returns and the socket
  closes; for a live client it's one extra `: keepalive` comment line.
  Logs a warning when 50+ streams are alive at once, far more than this
  app's handful of MCP clients.

  Off in test (`config :trading_options_sim, :mcp_sse_reaper, false`), so
  the MCP integration tests' streams get no unexpected writes. The real
  fix belongs upstream in anubis_mcp.
  """

  use GenServer

  require Logger

  @interval_ms :timer.seconds(30)
  @warn_at 50
  @stream_loop {Anubis.SSE.Streaming, :loop, 5}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Nudges every stream process now; returns how many. For tests and RPC."
  @spec nudge_now(GenServer.server()) :: non_neg_integer()
  def nudge_now(server \\ __MODULE__), do: GenServer.call(server, :nudge_now)

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
      stream_loop: Keyword.get(opts, :stream_loop, @stream_loop)
    }

    schedule(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:nudge_now, _from, state), do: {:reply, nudge(state), state}

  @impl true
  def handle_info(:nudge, state) do
    nudge(state)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  defp nudge(state) do
    streams = stream_processes(state.stream_loop)
    Enum.each(streams, &send(&1, :sse_keepalive))
    count = length(streams)

    if count >= @warn_at do
      Logger.warning(
        "TradingOptionsSim.MCP.SseStreamReaper: #{count} MCP SSE stream processes alive; " <>
          "streams to gone clients should end after a nudge or two"
      )
    end

    count
  end

  # Only current_function is read per process: cheap even with thousands.
  defp stream_processes(stream_loop) do
    Enum.filter(Process.list(), fn pid ->
      pid != self() and Process.info(pid, :current_function) == {:current_function, stream_loop}
    end)
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :nudge, interval_ms)
end
