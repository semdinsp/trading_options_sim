defmodule TradingOptionsSim.MCP.SseStreamReaperTest do
  use ExUnit.Case, async: true

  alias TradingOptionsSim.MCP.SseStreamReaper

  # A stand-in for Anubis.SSE.Streaming.loop/5: parks in a named function
  # and reports each message it gets to the test.
  defmodule FakeStream do
    def loop(test_pid) do
      receive do
        :stop -> :ok
        msg -> send(test_pid, {:stream_got, self(), msg}) && loop(test_pid)
      end
    end
  end

  defp start_stream do
    test = self()
    pid = spawn(fn -> FakeStream.loop(test) end)
    # Wait until it's parked in loop/1.
    Enum.find_value(1..100, fn _ ->
      Process.info(pid, :current_function) == {:current_function, {FakeStream, :loop, 1}} ||
        (Process.sleep(2) && false)
    end)

    on_exit(fn -> send(pid, :stop) end)
    pid
  end

  defp start_reaper do
    name = :"reaper_#{System.unique_integer([:positive])}"

    start_supervised!(
      {SseStreamReaper,
       name: name, stream_loop: {FakeStream, :loop, 1}, interval_ms: :timer.hours(1)}
    )

    name
  end

  test "sends :sse_keepalive to every process parked in the stream loop" do
    a = start_stream()
    b = start_stream()
    reaper = start_reaper()

    assert SseStreamReaper.nudge_now(reaper) == 2
    assert_receive {:stream_got, ^a, :sse_keepalive}
    assert_receive {:stream_got, ^b, :sse_keepalive}
  end

  # Must not fire on healthy input: nothing else is touched.
  test "leaves processes that aren't in the stream loop alone" do
    test = self()
    other = spawn(fn -> receive do: (msg -> send(test, {:other_got, msg})) end)
    reaper = start_reaper()

    assert SseStreamReaper.nudge_now(reaper) == 0
    refute_receive {:other_got, _}
    send(other, :done)
  end

  test "is off in the test config" do
    assert Application.get_env(:trading_options_sim, :mcp_sse_reaper) == false
    refute Process.whereis(SseStreamReaper)
  end
end
