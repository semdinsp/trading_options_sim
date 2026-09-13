defmodule TradingOptionsSim.Pricing.BlackScholes do
  @moduledoc """
  Black-Scholes theoretical price and greeks for a European-style option
  — this app's v1 synthetic pricer (see
  `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §5a). Computes a theoretical price
  from the underlying's real tick, a configurable implied-vol input, and
  time-to-expiry, entirely local — no dependency on `tws_api`/
  `trading_hub`'s option market-data work.

  Deliberately uses plain `float` arithmetic throughout, not `Decimal` —
  the Black-Scholes formula involves `:math.exp/1`/`:math.log/1`/the
  normal CDF, none of which `Decimal` supports; this is a genuinely
  numerical computation, unlike the exact dollar arithmetic
  `trading_core`'s `PositionSizing`/`RiskControls` do. Callers that need
  a `Decimal` result (e.g. to compare against a `Decimal` strike/rule
  value) convert at their own boundary — this module's job is only the
  numerical pricing itself.

  This is a standard textbook formula (Black & Scholes 1973 / Merton
  1973, non-dividend-paying underlying) — no proprietary vol surface,
  no American-exercise early-exercise premium (this app never models
  assignment/exercise mechanics either — see plan §7).
  """

  @type inputs :: %{
          spot: float(),
          strike: float(),
          time_to_expiry_years: float(),
          risk_free_rate: float(),
          volatility: float(),
          right: String.t()
        }

  @type result :: %{
          price: float(),
          delta: float(),
          gamma: float(),
          theta: float(),
          vega: float()
        }

  @doc """
  Computes theoretical price and greeks. `right` is `"C"` or `"P"`.
  `time_to_expiry_years` must be positive — see `price_at_expiry/1` for
  the `<= 0` (already-expired) case, which this function does not
  handle (division by zero in `d1`/`d2` otherwise).

  `theta` is returned as the per-YEAR rate of decay (the raw partial
  derivative) — divide by 365 for a per-day figure if that's what a
  caller displays; not done here so callers needing per-year and
  per-day both have exactly one source value to convert from.
  """
  @spec compute(inputs()) :: result()
  def compute(%{
        spot: spot,
        strike: strike,
        time_to_expiry_years: t,
        risk_free_rate: r,
        volatility: sigma,
        right: right
      })
      when t > 0 and spot > 0 and strike > 0 and sigma > 0 do
    d1 = d1(spot, strike, t, r, sigma)
    d2 = d2(d1, sigma, t)

    case right do
      "C" -> call(spot, strike, t, r, sigma, d1, d2)
      "P" -> put(spot, strike, t, r, sigma, d1, d2)
    end
  end

  @doc """
  Intrinsic value only — the correct price for an already-expired (or
  expiring-now) contract, where `compute/1`'s `d1`/`d2` would divide by
  zero. `right` is `"C"` or `"P"`.
  """
  @spec price_at_expiry(float(), float(), String.t()) :: float()
  def price_at_expiry(spot, strike, "C"), do: max(spot - strike, 0.0)
  def price_at_expiry(spot, strike, "P"), do: max(strike - spot, 0.0)

  defp d1(spot, strike, t, r, sigma) do
    (:math.log(spot / strike) + (r + sigma * sigma / 2) * t) / (sigma * :math.sqrt(t))
  end

  defp d2(d1, sigma, t), do: d1 - sigma * :math.sqrt(t)

  defp call(spot, strike, t, r, sigma, d1, d2) do
    nd1 = norm_cdf(d1)
    nd2 = norm_cdf(d2)
    discount = :math.exp(-r * t)

    %{
      price: spot * nd1 - strike * discount * nd2,
      delta: nd1,
      gamma: gamma(spot, sigma, t, d1),
      theta: call_theta(spot, strike, t, r, sigma, d1, d2, discount, nd2),
      vega: vega(spot, t, d1)
    }
  end

  defp put(spot, strike, t, r, sigma, d1, d2) do
    n_neg_d1 = norm_cdf(-d1)
    n_neg_d2 = norm_cdf(-d2)
    discount = :math.exp(-r * t)

    %{
      price: strike * discount * n_neg_d2 - spot * n_neg_d1,
      delta: n_neg_d1 - 1.0,
      gamma: gamma(spot, sigma, t, d1),
      theta: put_theta(spot, strike, t, r, sigma, d1, d2, discount, n_neg_d2),
      vega: vega(spot, t, d1)
    }
  end

  # Gamma and vega are identical for calls and puts (Black-Scholes).
  defp gamma(spot, sigma, t, d1) do
    norm_pdf(d1) / (spot * sigma * :math.sqrt(t))
  end

  defp vega(spot, t, d1) do
    spot * norm_pdf(d1) * :math.sqrt(t)
  end

  defp call_theta(spot, strike, t, r, sigma, d1, _d2, discount, nd2) do
    term1 = -(spot * norm_pdf(d1) * sigma) / (2 * :math.sqrt(t))
    term2 = -r * strike * discount * nd2
    term1 + term2
  end

  defp put_theta(spot, strike, t, r, sigma, d1, _d2, discount, n_neg_d2) do
    term1 = -(spot * norm_pdf(d1) * sigma) / (2 * :math.sqrt(t))
    term2 = r * strike * discount * n_neg_d2
    term1 + term2
  end

  # Standard normal PDF.
  defp norm_pdf(x) do
    :math.exp(-x * x / 2) / :math.sqrt(2 * :math.pi())
  end

  # Standard normal CDF via the Abramowitz & Stegun 7.1.26 approximation
  # (error < 1.5e-7) — no erf/2 in Elixir's :math, and this app has no
  # need for a full stats library just for this one function.
  @a1 0.254829592
  @a2 -0.284496736
  @a3 1.421413741
  @a4 -1.453152027
  @a5 1.061405429
  @p 0.3275911

  defp norm_cdf(x) do
    sign = if x < 0, do: -1.0, else: 1.0
    x = abs(x) / :math.sqrt(2)

    t = 1.0 / (1.0 + @p * x)
    y = 1.0 - ((((@a5 * t + @a4) * t + @a3) * t + @a2) * t + @a1) * t * :math.exp(-x * x)

    0.5 * (1.0 + sign * y)
  end
end
