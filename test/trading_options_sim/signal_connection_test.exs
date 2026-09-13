defmodule TradingOptionsSim.SignalConnectionTest do
  use ExUnit.Case, async: true

  alias TradingOptionsSim.SignalConnection

  # safe_erpc/4 called against node() (self) reproduces :erpc.call/5's
  # real remote-failure shapes without needing a second distributed node
  # — confirmed: :erpc.call/5 re-raises identically whether the target
  # is node() or a genuinely remote one, since the wrapping happens on
  # the calling side regardless of which node actually ran the code.
  # Ported from TradingLive.SignalConnectionTest's identical suite.
  describe "safe_erpc/4" do
    test "a successful remote call returns {:ok, result} unwrapped from a bare value" do
      assert {:ok, 3} = SignalConnection.safe_erpc(node(), Kernel, :+, [1, 2])
    end

    test "a remote {:ok, _} return is passed through, not double-wrapped" do
      assert {:ok, :already_ok} =
               SignalConnection.safe_erpc(node(), Function, :identity, [{:ok, :already_ok}])
    end

    test "a remote {:error, _} return is passed through, not mistaken for erpc failure" do
      assert {:error, :remote_said_no} =
               SignalConnection.safe_erpc(
                 node(),
                 Function,
                 :identity,
                 [{:error, :remote_said_no}]
               )
    end

    test "the remote function raising an exception is caught as {:error, reason}" do
      assert {:error, %RuntimeError{message: "boom"}} =
               SignalConnection.safe_erpc(node(), __MODULE__, :raise_runtime_error, [])
    end

    test "an unreachable node is caught as {:error, reason}, not left to crash the caller" do
      assert {:error, _reason} =
               SignalConnection.safe_erpc(
                 :nonexistent@nowhere,
                 Kernel,
                 :+,
                 [1, 2]
               )
    end

    def raise_runtime_error, do: raise(RuntimeError, "boom")
  end

  describe "request_signal/1" do
    test "returns {:error, reason} rather than crashing or hanging when trading_signal can't be reached" do
      # SignalConnection is always started in every env (see
      # application.ex). Whether it reports {:error, :not_connected} (no
      # distributed-Erlang link at all) or {:error, _} from a remote call
      # that can't complete depends on what's actually running on this
      # machine when the suite runs. Either way, this must never raise or
      # hang — same "always {:error, _}, never a crash" guarantee
      # safe_erpc/4's own tests already assert.
      assert {:error, _reason} = SignalConnection.request_signal("some_signal")
    end
  end

  describe "connected?/0" do
    test "returns a boolean without raising" do
      assert is_boolean(SignalConnection.connected?())
    end
  end
end
