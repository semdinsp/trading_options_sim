defmodule TradingOptionsSim.Pricing.ResubscribeBackoff do
  @moduledoc """
  Keeps retrying a hub subscription until trading_hub accepts it.

  Shared by the three subscription holders: `UnderlyingSubscription`,
  `PolygonSubscription` and `IBKRLive`.

  Each holder used to try once and give up. On 2026-09-25 trading_hub
  restarted during market hours. The underlying holders saw `:nodeup` and
  re-subscribed at once. The hub node was up but not yet taking
  subscriptions, so every attempt failed and nothing retried. TLT then had
  no subscription anywhere, and SPY/QQQ only ticked because other apps
  held them. `IBKRLive` had no re-subscribe path at all, so 30 of 31
  option listeners went stale until the node was restarted.

  Call `after_attempt/1` after any subscribe attempt: at start-up, on
  `:nodeup`, or on a health broadcast.
  - Success clears the retry state.
  - Failure schedules `:retry_subscribe` to the calling process. The delay
    doubles from the base (default 2s) and is capped at 60s.
  - Only one retry is ever pending.
  - Retries continue until the hub accepts, so a hub that is down for a
    long time costs one cheap RPC a minute.

  The holder's state must have `subscribed?`, `retry_attempt` and
  `retry_timer` fields.
  """

  @default_base_ms 2_000
  @max_delay_ms 60_000

  @doc "Updates `state` after a subscribe attempt; see the moduledoc."
  def after_attempt(%{subscribed?: true, retry_timer: timer} = state) do
    if is_reference(timer), do: Process.cancel_timer(timer)
    %{state | retry_attempt: 0, retry_timer: nil}
  end

  def after_attempt(%{retry_timer: timer} = state) when is_reference(timer), do: state

  def after_attempt(%{retry_attempt: attempt} = state) do
    next = attempt + 1
    timer = Process.send_after(self(), :retry_subscribe, delay_ms(next))
    %{state | retry_attempt: next, retry_timer: timer}
  end

  @doc "Delay before retry `attempt` (1-based): base × 2^(attempt-1), capped at 60s."
  @spec delay_ms(pos_integer()) :: pos_integer()
  def delay_ms(attempt) do
    base = Application.get_env(:trading_options_sim, :resubscribe_retry_base_ms, @default_base_ms)
    min(base * Integer.pow(2, min(attempt - 1, 20)), @max_delay_ms)
  end
end
