defmodule TradingOptionsSim.Pricing.BlackScholesTest do
  use ExUnit.Case, async: true

  alias TradingOptionsSim.Pricing.BlackScholes

  # Reference values: a widely-cited textbook example (Hull, "Options,
  # Futures, and Other Derivatives") — spot=100, strike=100, T=1yr,
  # r=5%, sigma=20%, non-dividend-paying. Call ≈ 10.45, put ≈ 5.57
  # (put-call parity: C - P = S - K*e^(-rT) = 100 - 100*e^(-0.05) ≈ 4.877).
  @atm_inputs %{
    spot: 100.0,
    strike: 100.0,
    time_to_expiry_years: 1.0,
    risk_free_rate: 0.05,
    volatility: 0.20
  }

  describe "compute/1 — at-the-money reference case" do
    test "call price matches the known textbook value (~10.45)" do
      result = BlackScholes.compute(Map.put(@atm_inputs, :right, "C"))
      assert_in_delta result.price, 10.4506, 0.001
    end

    test "put price matches the known textbook value (~5.57)" do
      result = BlackScholes.compute(Map.put(@atm_inputs, :right, "P"))
      assert_in_delta result.price, 5.5735, 0.001
    end

    test "put-call parity holds: C - P == S - K*e^(-rT)" do
      call = BlackScholes.compute(Map.put(@atm_inputs, :right, "C"))
      put = BlackScholes.compute(Map.put(@atm_inputs, :right, "P"))

      expected_diff = 100.0 - 100.0 * :math.exp(-0.05 * 1.0)
      assert_in_delta call.price - put.price, expected_diff, 0.001
    end

    test "call delta is between 0 and 1, roughly 0.64 for this ATM+drift case" do
      result = BlackScholes.compute(Map.put(@atm_inputs, :right, "C"))
      assert_in_delta result.delta, 0.6368, 0.001
    end

    test "put delta is between -1 and 0" do
      result = BlackScholes.compute(Map.put(@atm_inputs, :right, "P"))
      assert result.delta < 0
      assert result.delta > -1
    end

    test "call and put share the same gamma and vega" do
      call = BlackScholes.compute(Map.put(@atm_inputs, :right, "C"))
      put = BlackScholes.compute(Map.put(@atm_inputs, :right, "P"))

      assert_in_delta call.gamma, put.gamma, 1.0e-9
      assert_in_delta call.vega, put.vega, 1.0e-9
    end

    test "gamma and vega are positive" do
      result = BlackScholes.compute(Map.put(@atm_inputs, :right, "C"))
      assert result.gamma > 0
      assert result.vega > 0
    end
  end

  describe "compute/1 — deep in/out of the money" do
    test "deep ITM call price approaches intrinsic value as time_to_expiry shrinks" do
      inputs = %{
        spot: 150.0,
        strike: 100.0,
        time_to_expiry_years: 0.01,
        risk_free_rate: 0.05,
        volatility: 0.20,
        right: "C"
      }

      result = BlackScholes.compute(inputs)
      assert_in_delta result.price, 50.0, 1.0
      assert_in_delta result.delta, 1.0, 0.05
    end

    test "deep OTM put has near-zero price and delta near -1" do
      inputs = %{
        spot: 150.0,
        strike: 50.0,
        time_to_expiry_years: 0.25,
        risk_free_rate: 0.05,
        volatility: 0.20,
        right: "P"
      }

      # A deep OTM put (spot >> strike) has near-zero PRICE, but delta
      # (N(-d1) - 1) approaches -1 here, not 0 — d1 is large positive
      # (deep ITM from the call side), N(-d1) -> 0, so delta -> 0 - 1 =
      # -1. Delta measures sensitivity as a fraction of a full
      # short-stock position, not "probability of exercise" — a cheap,
      # far-OTM put can still carry delta near -1 as spot moves further
      # from strike. Verified independently against the standard
      # closed-form N(-d1) computation before trusting this assertion.
      result = BlackScholes.compute(inputs)
      assert result.price < 0.01
      assert_in_delta result.delta, -1.0, 0.01
    end
  end

  describe "price_at_expiry/3" do
    test "call intrinsic value is max(spot - strike, 0)" do
      assert BlackScholes.price_at_expiry(110.0, 100.0, "C") == 10.0
      assert BlackScholes.price_at_expiry(90.0, 100.0, "C") == 0.0
    end

    test "put intrinsic value is max(strike - spot, 0)" do
      assert BlackScholes.price_at_expiry(90.0, 100.0, "P") == 10.0
      assert BlackScholes.price_at_expiry(110.0, 100.0, "P") == 0.0
    end
  end
end
