defmodule TradingOptionsSim.RegimeEdge do
  @moduledoc """
  The regime-edge test: does a losing version have a proven edge in one
  market regime? If so, the automatic retirement steps keep it.

  Shared definition with trading_system (its PR #497, revised 2026-11-21)
  and trading_live, so the three apps agree:

    * Buckets are `regime_label` at ENTRY (trading_signal's `"vol|trend"`,
      e.g. `"normal|chop"`); no label is `"uncategorized"`.
    * R is net P&L over `risk_at_entry` (premium at risk here), churn and
      excluded runs out (`Sim.regime_edge/1` builds the per-session rows).
    * Each session's closes are averaged first. The statistic is the mean
      of those session means (`mean_session_r`), and the bound is
      session-clustered: `mean - z * sd / sqrt(n_sessions)` over the
      session means.
    * Floor: at least #{20} closes over at least #{10} sessions.
    * `z = Φ⁻¹(1 - α/k)`, α = 0.05 one-sided, k = the version's buckets
      that meet the floor (a Bonferroni correction for testing k regimes).
    * Edge only when that lower bound is > 0. There is no mean-only arm.

  `"uncategorized"` counts towards k (it was tested) but can never be the
  edge: an unknown regime can't be gated on.

  Pure functions only; the query lives in `Sim.regime_edge/1`.
  """

  @min_closes 20
  @min_sessions 10
  @alpha 0.05
  @uncategorized "uncategorized"

  def min_closes, do: @min_closes
  def min_sessions, do: @min_sessions

  @doc """
  Evaluates one version's buckets.

  `buckets` is a list of `%{regime_label, n_closes, n_sessions,
  mean_session_r, sd_session_r}` (floats or Decimals; `sd` nil for one
  session). Returns `%{has_edge, k, z, buckets, edges}`, where `buckets`
  holds only the buckets meeting the floor (each with `lcb95` and `z`)
  and `edges` those of them with `lcb95 > 0`, best bound first.
  """
  @spec evaluate([map()]) :: map()
  def evaluate(buckets) do
    qualifying =
      Enum.filter(buckets, &(&1.n_closes >= @min_closes and &1.n_sessions >= @min_sessions))

    k = length(qualifying)
    z = if k > 0, do: z_for(k), else: nil

    scored =
      qualifying
      |> Enum.map(fn b ->
        mean = to_float(b.mean_session_r)
        sd = to_float(b.sd_session_r || 0)

        b
        |> Map.take([:regime_label, :n_closes, :n_sessions])
        |> Map.merge(%{
          mean_session_r: mean,
          lcb95: mean - z * sd / :math.sqrt(b.n_sessions),
          z: z
        })
      end)
      |> Enum.sort_by(&{-&1.n_closes, &1.regime_label})

    edges =
      scored
      |> Enum.filter(&(&1.lcb95 > 0 and &1.regime_label != @uncategorized))
      |> Enum.sort_by(& &1.lcb95, :desc)

    %{has_edge: edges != [], k: k, z: z, buckets: scored, edges: edges}
  end

  @doc "One-sided critical value after a Bonferroni correction for `k` tests."
  @spec z_for(pos_integer()) :: float()
  def z_for(k) when is_integer(k) and k >= 1, do: inverse_normal_cdf(1 - @alpha / k)

  @doc "A one-line description of an edge for logs and reports."
  @spec describe(map()) :: String.t()
  def describe(%{
        regime_label: l,
        mean_session_r: m,
        lcb95: lcb,
        n_closes: n,
        n_sessions: s,
        z: z
      }) do
    "regime-edge: #{l} #{signed(m)}R, lcb #{signed(lcb)}, #{n} closes / #{s} sessions, z #{Float.round(z, 3)}"
  end

  @doc """
  Φ⁻¹(p) for 0 < p < 1 (Acklam's rational approximation, relative error
  below 1.2e-9; ample for a z-score).
  """
  @spec inverse_normal_cdf(float()) :: float()
  def inverse_normal_cdf(p) when p > 0 and p < 1 do
    a = [
      -39.69683028665376,
      220.9460984245205,
      -275.9285104469687,
      138.3577518672690,
      -30.66479806614716,
      2.506628277459239
    ]

    b = [
      -54.47609879822406,
      161.5858368580409,
      -155.6989798598866,
      66.80131188771972,
      -13.28068155288572
    ]

    c = [
      -0.007784894002430293,
      -0.3223964580411365,
      -2.400758277161838,
      -2.549732539343734,
      4.374664141464968,
      2.938163982698783
    ]

    d = [0.007784695709041462, 0.3224671290700398, 2.445134137142996, 3.754408661907416]
    p_low = 0.02425

    cond do
      p < p_low ->
        q = :math.sqrt(-2 * :math.log(p))
        poly(c, q) / (poly(d, q) * q + 1)

      p <= 1 - p_low ->
        q = p - 0.5
        r = q * q
        poly(a, r) * q / (poly(b, r) * r + 1)

      true ->
        q = :math.sqrt(-2 * :math.log(1 - p))
        -(poly(c, q) / (poly(d, q) * q + 1))
    end
  end

  # Horner: coefficients highest power first.
  defp poly(coeffs, x), do: Enum.reduce(coeffs, 0.0, &(&2 * x + &1))

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n / 1

  defp signed(x) when x >= 0, do: "+#{Float.round(x, 2)}"
  defp signed(x), do: "#{Float.round(x, 2)}"
end
