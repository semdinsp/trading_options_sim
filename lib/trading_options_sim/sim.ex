defmodule TradingOptionsSim.Sim do
  @moduledoc """
  The Sim context — strategies, versions, lifecycle transitions, target
  pools, and tags. See `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §2/§3/§3a.
  """

  import Ecto.Query

  alias TradingOptionsSim.Repo

  alias TradingOptionsSim.Sim.{
    ApiToken,
    ExchangeSession,
    PerformanceSnapshot,
    SimFill,
    SimRun,
    Strategy,
    StrategyVersion,
    Tag,
    TargetPool,
    TargetPoolMember
  }

  # --- Strategies -----------------------------------------------------------

  def create_strategy(attrs) do
    %Strategy{}
    |> Strategy.changeset(attrs)
    |> Repo.insert()
  end

  def get_strategy!(id), do: Repo.get!(Strategy, id)

  def list_strategies do
    Repo.all(Strategy)
  end

  def set_strategy_notes(%Strategy{} = strategy, notes) do
    strategy
    |> Strategy.notes_changeset(%{notes: notes})
    |> Repo.update()
  end

  # --- Strategy versions ------------------------------------------------------

  @doc """
  Sets `tags: []` on the freshly-inserted struct rather than preloading —
  a brand-new version can't have any tags yet, and this avoids a wasted
  round-trip while still satisfying `Serializer.strategy_version/1`'s
  requirement that `:tags` be loaded (was `Ecto.Association.NotLoaded`
  otherwise, since `Repo.insert/1`'s result never preloads associations).
  """
  def create_strategy_version(%Strategy{} = strategy, attrs) do
    %StrategyVersion{}
    |> StrategyVersion.changeset(put_key(attrs, :strategy_id, strategy.id))
    |> Repo.insert()
    |> case do
      {:ok, version} -> {:ok, %{version | tags: []}}
      error -> error
    end
  end

  @doc """
  Preloads `:tags` — every real caller either needs it (any path that
  ends up serialized via `TradingOptionsSimWeb.Api.Serializer.strategy_version/1`,
  which requires it loaded) or is unaffected by the extra join (an
  internal re-fetch before a lifecycle/activation update). Was
  previously bare `Repo.get!/2`, with `StrategyVersionsLive` working
  around the gap itself with a manual `Repo.preload(:tags)` call after
  — folded in here instead of leaving every other caller (the API
  controller, every MCP tool) to hit the same `Ecto.Association.NotLoaded`
  crash on serialization.
  """
  def get_strategy_version!(id), do: Repo.get!(StrategyVersion, id) |> Repo.preload(:tags)

  @doc """
  `get_strategy_version!/1` preloaded with everything
  `StrategyVersionDetailLive` needs to render in one query: `:strategy`,
  `:tags`, and `target_pool: :target_pool_members` (the version's own
  target pool may be `nil` — a version can exist before one is set, see
  `SimActivator.activate/1`'s own `:no_target_pool` error clause — so
  this is a plain preload, not an inner join).
  """
  @spec get_strategy_version_detail!(String.t()) :: StrategyVersion.t()
  def get_strategy_version_detail!(id) do
    StrategyVersion
    |> Repo.get!(id)
    |> Repo.preload([:strategy, :tags, target_pool: :target_pool_members])
  end

  @doc """
  Preloads `:tags` — `GetStrategy` (MCP) surfaces each version's tags
  alongside its notes/activation status, matching the detail every other
  version listing (`list_strategy_versions/1`, `ListStrategyVersions` MCP
  tool) already includes.
  """
  def list_strategy_versions_for_strategy(%Strategy{id: strategy_id}) do
    StrategyVersion
    |> where([v], v.strategy_id == ^strategy_id)
    |> order_by([v], asc: v.version)
    |> preload(:tags)
    |> Repo.all()
  end

  @doc """
  Every `StrategyVersion` across every strategy, most-recently-updated
  first, optionally filtered to one `lifecycle_stage` — the Strategy
  Versions page's data source (`StrategyVersion.lifecycle_stages/0`
  covers "discovery"/"quarantine"/"test_portfolio"/"retired", so this
  one function/page also serves as the retired-strategies view, per
  `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §9's UI gaps). Preloads `:strategy`
  and `:tags` since every real use of this list shows both.
  """
  @spec list_strategy_versions(String.t() | nil) :: [StrategyVersion.t()]
  def list_strategy_versions(lifecycle_stage \\ nil) do
    StrategyVersion
    |> maybe_filter_lifecycle_stage(lifecycle_stage)
    |> order_by([v], desc: v.updated_at)
    |> preload([:strategy, :tags])
    |> Repo.all()
  end

  @doc """
  Paginated `StrategyVersion` listing for `/api/v1/versions` and the
  `list_strategy_versions` MCP tool — same filtering/ordering/preloads
  as `list_strategy_versions/1`, bounded by `limit`/`offset` (clamped
  to `@max_page_size`, same as `list_sim_runs_page/2`). Returns
  `{versions, total_count}`.
  """
  @spec list_strategy_versions_page(String.t() | nil, keyword()) ::
          {[StrategyVersion.t()], non_neg_integer()}
  def list_strategy_versions_page(lifecycle_stage \\ nil, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> clamp_page_size()
    offset = max(Keyword.get(opts, :offset, 0), 0)

    base_query = StrategyVersion |> maybe_filter_lifecycle_stage(lifecycle_stage)

    total_count = base_query |> select([v], count(v.id)) |> Repo.one()

    versions =
      base_query
      |> order_by([v], desc: v.updated_at)
      |> limit(^limit)
      |> offset(^offset)
      |> preload([:strategy, :tags])
      |> Repo.all()

    {versions, total_count}
  end

  defp maybe_filter_lifecycle_stage(query, nil), do: query

  defp maybe_filter_lifecycle_stage(query, stage),
    do: where(query, [v], v.lifecycle_stage == ^stage)

  @doc """
  Total `StrategyVersion` count per `lifecycle_stage`, across every
  strategy — a stable, whole-system orientation number (never scoped to
  `list_strategy_versions/1`'s own `stage_filter`), same purpose as
  `trading_system`'s `Trading.strategy_version_stage_counts/0` (which
  `TradingSystemWeb.TradingComponents.stage_counts_strip/1` renders).
  Returns a plain `%{"discovery" => n, "quarantine" => n, ...}` map —
  a stage with zero rows is simply absent from the map, not `0`; the
  caller (`stage_counts_strip/1`) defaults each key it reads.
  """
  @spec strategy_version_stage_counts() :: %{String.t() => non_neg_integer()}
  def strategy_version_stage_counts do
    StrategyVersion
    |> where([v], is_nil(v.deleted_at))
    |> group_by([v], v.lifecycle_stage)
    |> select([v], {v.lifecycle_stage, count(v.id)})
    |> Repo.all()
    |> Map.new()
  end

  def set_strategy_version_rating(%StrategyVersion{} = version, rating) do
    version
    |> StrategyVersion.rating_changeset(%{rating: rating})
    |> Repo.update()
  end

  def set_strategy_version_notes(%StrategyVersion{} = version, notes) do
    version
    |> StrategyVersion.notes_changeset(%{notes: notes})
    |> Repo.update()
  end

  @doc """
  Sets `trading_hours_policy` and/or `overnight_hold` — `attrs` may
  include either or both keys. See `StrategyVersion.operational_changeset/2`'s
  own doc for why this is a separate, deliberate-exception changeset.
  """
  @spec update_trading_hours_settings(StrategyVersion.t(), map()) ::
          {:ok, StrategyVersion.t()} | {:error, Ecto.Changeset.t()}
  def update_trading_hours_settings(%StrategyVersion{} = version, attrs) do
    version
    |> StrategyVersion.operational_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Marks `version` as durably active — sets `activated_at` to now,
  clears `deactivated_at`. Called by `SimActivator.activate/1` on every
  call (even a no-op re-activation against an already-running monitor),
  so `activated_at` always reflects the most recent activation. See
  `StrategyVersion.activated_at`'s own doc for why this exists as a
  persistent field rather than being derived from `SimRun` state.

  Re-fetches `version` by id before building the changeset rather than
  trusting the caller's own (possibly stale) struct — confirmed via a
  real bug: `Ecto.Repo.update/2` only emits SQL for fields that differ
  from the struct's own in-memory value, so a caller re-activating with
  a `version` struct loaded before an earlier `deactivate/1` call (which
  writes `deactivated_at` straight to the DB, not to that in-memory
  struct) produced a changeset where `deactivated_at: nil` looked like
  "no change" (`nil -> nil` in memory) and silently never reached the
  UPDATE statement, leaving the DB row's stale `deactivated_at`
  unchanged even though `activated_at` was written correctly.
  """
  @spec mark_activated(StrategyVersion.t()) ::
          {:ok, StrategyVersion.t()} | {:error, Ecto.Changeset.t()}
  def mark_activated(%StrategyVersion{id: id}) do
    id
    |> get_strategy_version!()
    |> StrategyVersion.activation_changeset(%{
      activated_at: DateTime.utc_now() |> DateTime.truncate(:second),
      deactivated_at: nil
    })
    |> Repo.update()
  end

  @doc """
  Marks `version` as durably deactivated — sets `deactivated_at` to
  now. Called by `SimActivator.deactivate/1` unconditionally (even for
  a version with zero running monitors to stop), so "deactivated" is
  never left stale after an explicit deactivate action.
  """
  @spec mark_deactivated(StrategyVersion.t()) ::
          {:ok, StrategyVersion.t()} | {:error, Ecto.Changeset.t()}
  def mark_deactivated(%StrategyVersion{} = version) do
    version
    |> StrategyVersion.activation_changeset(%{
      deactivated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end

  # --- Lifecycle --------------------------------------------------------------
  #
  # Three stages: discovery -> quarantine -> test_portfolio, plus terminal
  # retired (unretireable back to discovery). No "live" stage — see
  # StrategyVersion's own moduledoc.

  @doc """
  Promotes `version` to `to` (one of `"quarantine"`, `"test_portfolio"`,
  or `"discovery"` — the last only valid from `"retired"`, i.e.
  "unretire"). `discovery -> quarantine` requires a `target_pool_id` and
  sets `quarantine_started_at`/resets `quarantine_trading_days`, mirroring
  `trading_system.promote_strategy_version/2`.
  """
  @spec promote_strategy_version(StrategyVersion.t(), String.t()) ::
          {:ok, StrategyVersion.t()}
          | {:error, :invalid_transition}
          | {:error, :no_target_pool}
          | {:error, Ecto.Changeset.t()}
  def promote_strategy_version(
        %StrategyVersion{lifecycle_stage: "discovery", target_pool_id: nil},
        "quarantine"
      ) do
    {:error, :no_target_pool}
  end

  def promote_strategy_version(
        %StrategyVersion{lifecycle_stage: "discovery", target_pool_id: target_pool_id} = version,
        "quarantine"
      )
      when not is_nil(target_pool_id) do
    version
    |> StrategyVersion.lifecycle_stage_changeset(%{
      "lifecycle_stage" => "quarantine",
      "quarantine_started_at" => DateTime.utc_now() |> DateTime.truncate(:second),
      "quarantine_trading_days" => 0
    })
    |> Repo.update()
  end

  def promote_strategy_version(
        %StrategyVersion{lifecycle_stage: "quarantine"} = version,
        "test_portfolio"
      ) do
    version
    |> StrategyVersion.lifecycle_stage_changeset(%{"lifecycle_stage" => "test_portfolio"})
    |> Repo.update()
  end

  def promote_strategy_version(
        %StrategyVersion{lifecycle_stage: "retired"} = version,
        "discovery"
      ) do
    version
    |> StrategyVersion.lifecycle_stage_changeset(%{"lifecycle_stage" => "discovery"})
    |> Repo.update()
  end

  def promote_strategy_version(%StrategyVersion{}, to)
      when to in ["discovery", "quarantine", "test_portfolio", "retired"] do
    {:error, :invalid_transition}
  end

  @doc """
  Downgrades `version` to `to` (`"retired"` from any non-terminal stage,
  or `"quarantine"` from `"test_portfolio"`). `reason` is one of
  `StrategyVersion.retired_reasons/0`, only meaningful for a `"retired"`
  transition.
  """
  @spec downgrade_strategy_version(StrategyVersion.t(), String.t(), String.t()) ::
          {:ok, StrategyVersion.t()}
          | {:error, :invalid_transition}
          | {:error, Ecto.Changeset.t()}
  def downgrade_strategy_version(strategy_version, to, reason \\ "manual")

  def downgrade_strategy_version(
        %StrategyVersion{lifecycle_stage: stage} = version,
        "retired",
        reason
      )
      when stage in ["discovery", "quarantine", "test_portfolio"] do
    version
    |> StrategyVersion.lifecycle_stage_changeset(%{
      "lifecycle_stage" => "retired",
      "retired_reason" => reason
    })
    |> Repo.update()
  end

  def downgrade_strategy_version(
        %StrategyVersion{lifecycle_stage: "test_portfolio"} = version,
        "quarantine",
        _reason
      ) do
    version
    |> StrategyVersion.lifecycle_stage_changeset(%{"lifecycle_stage" => "quarantine"})
    |> Repo.update()
  end

  def downgrade_strategy_version(%StrategyVersion{}, to, _reason)
      when to in ["quarantine", "retired"] do
    {:error, :invalid_transition}
  end

  @doc """
  Records a link to `live_strategy_app`'s own strategy record on a
  `test_portfolio`-stage version — `lifecycle_stage` stays
  `test_portfolio`. Called by the pulling app's own promotion flow
  (e.g. `trading_live`) after it has already built its local record —
  see `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §4 for the corrected pull
  direction (this app never calls out to `trading_live`; `trading_live`
  calls in here).
  """
  @spec link_live_strategy(StrategyVersion.t(), String.t(), String.t()) ::
          {:ok, StrategyVersion.t()}
          | {:error, :invalid_transition}
          | {:error, Ecto.Changeset.t()}
  def link_live_strategy(
        %StrategyVersion{lifecycle_stage: "test_portfolio"} = version,
        live_strategy_app,
        live_strategy_id
      ) do
    version
    |> StrategyVersion.link_live_strategy_changeset(%{
      "live_strategy_app" => live_strategy_app,
      "live_strategy_id" => live_strategy_id,
      "live_strategy_active" => true,
      "live_linked_at" => DateTime.utc_now()
    })
    |> Repo.update()
  end

  def link_live_strategy(%StrategyVersion{}, _live_strategy_app, _live_strategy_id) do
    {:error, :invalid_transition}
  end

  @doc """
  Unlinks `version` from whichever `live_strategy_app` it was linked to
  — called when that app kills/deletes/unpromotes the strategy it was
  linked to. `{:error, :not_linked}` if `live_strategy_active` is
  already `false`. Leaves `live_strategy_app`/`live_strategy_id`/
  `live_linked_at` in place as history — see
  `StrategyVersion.unlink_live_strategy_changeset/2`'s own doc.
  """
  @spec unlink_live_strategy(StrategyVersion.t()) ::
          {:ok, StrategyVersion.t()} | {:error, :not_linked} | {:error, Ecto.Changeset.t()}
  def unlink_live_strategy(%StrategyVersion{live_strategy_active: false}) do
    {:error, :not_linked}
  end

  def unlink_live_strategy(%StrategyVersion{} = version) do
    version
    |> StrategyVersion.unlink_live_strategy_changeset(%{
      "live_strategy_active" => false,
      "live_unlinked_at" => DateTime.utc_now()
    })
    |> Repo.update()
  end

  # --- Quarantine eligibility (§2, "Difference from trading_system") --------

  # v1 fixed thresholds — no AppSettings-style runtime-configurable
  # schema exists in this app yet (trading_system's own version of these
  # is operator-tunable; not needed until there's real closed-run
  # history to tune against, per §2's own deferral note). Intentionally
  # much simpler than trading_system's real gates (no regime buckets, no
  # target-pool exclusion list, no expectancy_r-normalized check) — this
  # is a proportionate v1 for an app with no live-money consequence of
  # its own; trading_live's own gates are the real backstop before
  # capital follows a linked version.
  @quarantine_min_closed_runs 20
  @quarantine_min_realized_pnl Decimal.new(0)
  @quarantine_max_trading_days 20
  @quarantine_max_loss_ratio Decimal.new("2.0")

  @doc """
  Job 1 of the daily quarantine-eligibility check
  (`TradingOptionsSim.Sim.Workers.QuarantineEligibilityWorker`):
  increments `quarantine_trading_days` for every `quarantine`-stage
  version with at least one run that closed on `trading_date`, and
  stamps `quarantine_last_counted_date` on every quarantine version
  regardless (so a version with no run that day still records it was
  checked). `quarantine_last_counted_date != trading_date` guards
  against double-counting on an Oban retry — ported from
  `TradingSystem.Trading.update_quarantine_trading_days/1`'s identical
  idempotency guard.
  """
  @spec update_quarantine_trading_days(Date.t()) :: :ok
  def update_quarantine_trading_days(trading_date) do
    quarantine_versions =
      StrategyVersion
      |> where([v], v.lifecycle_stage == "quarantine")
      |> where(
        [v],
        is_nil(v.quarantine_last_counted_date) or v.quarantine_last_counted_date != ^trading_date
      )
      |> Repo.all()

    if quarantine_versions != [] do
      version_ids = Enum.map(quarantine_versions, & &1.id)

      versions_with_close_today =
        SimRun
        |> where([r], r.strategy_version_id in ^version_ids)
        |> where([r], r.status == "closed")
        |> where([r], fragment("?::date", r.exit_at) == ^trading_date)
        |> select([r], r.strategy_version_id)
        |> distinct(true)
        |> Repo.all()
        |> MapSet.new()

      Enum.each(quarantine_versions, fn version ->
        attrs =
          if MapSet.member?(versions_with_close_today, version.id) do
            %{
              "quarantine_trading_days" => version.quarantine_trading_days + 1,
              "quarantine_last_counted_date" => trading_date
            }
          else
            %{"quarantine_last_counted_date" => trading_date}
          end

        version
        |> StrategyVersion.lifecycle_stage_changeset(attrs)
        |> Repo.update!()
      end)
    end

    :ok
  end

  @doc """
  Job 2: auto-promotes every `discovery`-stage version with a
  `target_pool_id` set, at least `#{@quarantine_min_closed_runs}` closed
  runs, and non-negative total `realized_pnl` (strictly `>= 0`, matching
  `@quarantine_min_realized_pnl`) into `quarantine`. A version with no
  `target_pool_id` is skipped (stays in `discovery`, eligible again next
  run) — same gap `trading_system`'s own job closes for a version that
  slipped in before a pool was required; nothing here promotes an
  unscoped version into a stage where `lifecycle_stage_changeset/2`'s
  own "frozen while quarantined" rule would make fixing it require a
  fork.
  """
  @spec auto_promote_eligible_discovery_versions() :: {:ok, [StrategyVersion.t()]}
  def auto_promote_eligible_discovery_versions do
    discovery_version_ids =
      StrategyVersion
      |> where([v], v.lifecycle_stage == "discovery")
      |> where([v], not is_nil(v.target_pool_id))
      |> select([v], v.id)
      |> Repo.all()

    eligible_ids =
      discovery_version_ids
      |> Enum.filter(fn version_id ->
        stats = closed_run_stats(version_id)

        stats.closed_count >= @quarantine_min_closed_runs and
          Decimal.compare(stats.total_realized_pnl, @quarantine_min_realized_pnl) != :lt
      end)

    promoted =
      Enum.map(eligible_ids, fn version_id ->
        version = get_strategy_version!(version_id)
        {:ok, promoted_version} = promote_strategy_version(version, "quarantine")
        promoted_version
      end)

    {:ok, promoted}
  end

  @doc """
  Job 3: auto-retires (`reason: "failed_quarantine"`) every
  `quarantine`-stage version that has run at least
  `#{@quarantine_max_trading_days}` trading days AND whose losses
  outweigh its wins by more than `#{@quarantine_max_loss_ratio}}`x
  (`total_loss / total_win > #{@quarantine_max_loss_ratio}`, skipped —
  not retired — when `total_win` is zero, since a ratio against zero
  wins is undefined rather than infinitely bad: a version with zero
  wins and zero losses so far has nothing to judge yet, and one with
  losses but literally no wins is a `total_win: 0` edge case this
  simple v1 gate deliberately leaves for a human to look at rather than
  auto-retiring on a division by zero). Both conditions must hold —
  tenure alone (a version still net-positive after 20 days) is not a
  failure; magnitude alone (one bad early day) is not either. Ordered
  after jobs 1/2 in `run_quarantine_eligibility_check/1` for the same
  reason `trading_system`'s own worker runs its 3 jobs in sequence:
  job 1 must land today's day-count before this job judges tenure
  against it.
  """
  @spec auto_retire_failing_quarantine_versions() :: {:ok, [StrategyVersion.t()]}
  def auto_retire_failing_quarantine_versions do
    quarantine_version_ids =
      StrategyVersion
      |> where([v], v.lifecycle_stage == "quarantine")
      |> where([v], v.quarantine_trading_days >= @quarantine_max_trading_days)
      |> select([v], v.id)
      |> Repo.all()

    failing_ids =
      Enum.filter(quarantine_version_ids, fn version_id ->
        stats = closed_run_stats(version_id)

        Decimal.compare(stats.total_win, Decimal.new(0)) == :gt and
          Decimal.compare(
            Decimal.div(stats.total_loss, stats.total_win),
            @quarantine_max_loss_ratio
          ) == :gt
      end)

    retired =
      Enum.map(failing_ids, fn version_id ->
        version = get_strategy_version!(version_id)

        {:ok, retired_version} =
          downgrade_strategy_version(version, "retired", "failed_quarantine")

        retired_version
      end)

    {:ok, retired}
  end

  @doc """
  Runs jobs 1-3 in order for `trading_date` (defaults to yesterday, UTC
  — same default `trading_system`'s own
  `run_quarantine_eligibility_check/1` uses, and for the identical
  reason: a version's `quarantine_trading_days` should only ever
  advance for a fully-closed trading day, and this check runs early
  enough in the UTC day — see the `Oban.Plugins.Cron` entry in
  `config.exs` — that "today" (UTC) has not traded yet). Job 1's
  day-count update must land before job 3's tenure check reads it —
  see that job's own doc.
  """
  @spec run_quarantine_eligibility_check(Date.t()) :: :ok
  def run_quarantine_eligibility_check(trading_date \\ Date.add(Date.utc_today(), -1)) do
    update_quarantine_trading_days(trading_date)
    auto_promote_eligible_discovery_versions()
    auto_retire_failing_quarantine_versions()
    :ok
  end

  # Closed-run realized_pnl breakdown for one version — total (win +
  # loss combined, can be negative), and win/loss split as separate
  # non-negative totals (win: sum of positive realized_pnl; loss: sum
  # of |negative realized_pnl|) so callers can compute a loss ratio
  # without re-deriving the split themselves.
  defp closed_run_stats(version_id) do
    closed_runs =
      SimRun
      |> where([r], r.strategy_version_id == ^version_id)
      |> where([r], r.status == "closed")
      |> select([r], r.realized_pnl)
      |> Repo.all()

    Enum.reduce(
      closed_runs,
      %{
        closed_count: 0,
        total_realized_pnl: Decimal.new(0),
        total_win: Decimal.new(0),
        total_loss: Decimal.new(0)
      },
      fn pnl, acc ->
        pnl = pnl || Decimal.new(0)

        acc
        |> Map.update!(:closed_count, &(&1 + 1))
        |> Map.update!(:total_realized_pnl, &Decimal.add(&1, pnl))
        |> then(fn acc ->
          case Decimal.compare(pnl, Decimal.new(0)) do
            :lt -> Map.update!(acc, :total_loss, &Decimal.add(&1, Decimal.abs(pnl)))
            _ -> Map.update!(acc, :total_win, &Decimal.add(&1, pnl))
          end
        end)
      end
    )
  end

  # --- Target pools -------------------------------------------------------

  def create_target_pool(attrs) do
    %TargetPool{}
    |> TargetPool.changeset(attrs)
    |> Repo.insert()
  end

  def get_target_pool!(id), do: Repo.get!(TargetPool, id) |> Repo.preload(:target_pool_members)

  def list_target_pools do
    Repo.all(TargetPool)
  end

  def add_target_pool_member(%TargetPool{} = pool, attrs) do
    %TargetPoolMember{}
    |> TargetPoolMember.changeset(put_key(attrs, :target_pool_id, pool.id))
    |> Repo.insert()
  end

  def list_target_pool_members(%TargetPool{id: target_pool_id}) do
    TargetPoolMember
    |> where([m], m.target_pool_id == ^target_pool_id)
    |> Repo.all()
  end

  # --- Tags ---------------------------------------------------------------

  @doc "Upserts a `Tag` by exact name match, per `Tag`'s own moduledoc."
  def get_or_create_tag(name) do
    trimmed = String.trim(name)

    case Repo.get_by(Tag, name: trimmed) do
      nil ->
        %Tag{}
        |> Tag.changeset(%{name: trimmed})
        |> Repo.insert()

      tag ->
        {:ok, tag}
    end
  end

  def list_tags do
    Repo.all(Tag)
  end

  @doc """
  Deletes `tag` outright — removes it from every `StrategyVersion`/
  `SimRun` it's currently applied to (both join tables cascade via
  `on_delete: :delete_all`, per their own migrations) rather than
  leaving it dangling on any of them. Settings' tag management screen
  is the one real caller; this is a destructive, unrecoverable action
  by design (re-creating a tag by the same name afterward is a new
  row, with no memory of what it used to be applied to).
  """
  @spec delete_tag(Tag.t()) :: {:ok, Tag.t()} | {:error, Ecto.Changeset.t()}
  def delete_tag(%Tag{} = tag) do
    Repo.delete(tag)
  end

  @doc "Replaces `version`'s full tag set with `tag_ids` — an empty list clears every tag."
  def put_strategy_version_tags(%StrategyVersion{} = version, tag_ids) do
    tags = Repo.all(from t in Tag, where: t.id in ^tag_ids)

    version
    |> Repo.preload(:tags)
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(:tags, tags)
    |> Repo.update()
  end

  @doc "Get-or-creates `tag_name` and unions it onto `version`'s existing tags — a no-op if already present."
  def add_tag_to_strategy_version_by_name(%StrategyVersion{} = version, tag_name) do
    with {:ok, tag} <- get_or_create_tag(tag_name) do
      version = Repo.preload(version, :tags)
      existing_ids = Enum.map(version.tags, & &1.id)

      if tag.id in existing_ids do
        {:ok, version}
      else
        put_strategy_version_tags(version, existing_ids ++ [tag.id])
      end
    end
  end

  @doc "Removes one tag from `version`'s tag set by id — a no-op if it isn't currently applied."
  @spec remove_tag_from_strategy_version(StrategyVersion.t(), String.t()) ::
          {:ok, StrategyVersion.t()} | {:error, Ecto.Changeset.t()}
  def remove_tag_from_strategy_version(%StrategyVersion{} = version, tag_id) do
    version = Repo.preload(version, :tags)
    remaining_ids = version.tags |> Enum.reject(&(&1.id == tag_id)) |> Enum.map(& &1.id)
    put_strategy_version_tags(version, remaining_ids)
  end

  @doc "Replaces `run`'s full tag set with `tag_ids` — an empty list clears every tag. Mirrors `put_strategy_version_tags/2`."
  def put_run_tags(%SimRun{} = run, tag_ids) do
    tags = Repo.all(from t in Tag, where: t.id in ^tag_ids)

    run
    |> Repo.preload(:tags)
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(:tags, tags)
    |> Repo.update()
  end

  @doc "Get-or-creates `tag_name` and unions it onto `run`'s existing tags — a no-op if already present. Mirrors `add_tag_to_strategy_version_by_name/2`."
  def add_tag_to_run_by_name(%SimRun{} = run, tag_name) do
    with {:ok, tag} <- get_or_create_tag(tag_name) do
      run = Repo.preload(run, :tags)
      existing_ids = Enum.map(run.tags, & &1.id)

      if tag.id in existing_ids do
        {:ok, run}
      else
        put_run_tags(run, existing_ids ++ [tag.id])
      end
    end
  end

  # --- Sim runs / fills -----------------------------------------------------

  @doc "Opens a new `SimRun` for `version` against the resolved contract in `attrs`."
  def open_sim_run(%StrategyVersion{} = version, attrs) do
    %SimRun{}
    |> SimRun.changeset(put_key(attrs, :strategy_version_id, version.id))
    |> Repo.insert()
  end

  @doc """
  Preloads `:tags` — same reasoning as `get_strategy_version!/1`'s own
  doc: every real caller either needs it for serialization or is
  unaffected by the extra join. `RunsLive` previously worked around the
  gap itself with a manual `Repo.preload(:tags)` call.
  """
  def get_sim_run!(id), do: Repo.get!(SimRun, id) |> Repo.preload(:tags)

  @doc "Records the entry fill: creates the `entry`-kind `SimFill` and stamps `SimRun`'s own entry fields together."
  def record_entry_fill(%SimRun{} = run, fill_attrs, run_entry_attrs) do
    Repo.transaction(fn ->
      with {:ok, fill} <- create_sim_fill(run, Map.put(fill_attrs, :kind, "entry")),
           {:ok, run} <- SimRun.entry_changeset(run, run_entry_attrs) |> Repo.update() do
        {fill, run}
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc "Records the exit fill: creates the `exit`-kind `SimFill` and closes the run."
  def record_exit_fill(%SimRun{} = run, fill_attrs, run_exit_attrs) do
    Repo.transaction(fn ->
      with {:ok, fill} <- create_sim_fill(run, Map.put(fill_attrs, :kind, "exit")),
           {:ok, run} <- SimRun.exit_changeset(run, run_exit_attrs) |> Repo.update() do
        {fill, run}
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp create_sim_fill(%SimRun{} = run, attrs) do
    %SimFill{}
    |> SimFill.changeset(put_key(attrs, :sim_run_id, run.id))
    |> Repo.insert()
  end

  # TODO: once a strategy can actually set/exercise a real stop-loss
  # (SimRun.stop_loss_price has no writer anywhere in this codebase as
  # of 2026-09-15 — confirmed by grep), a stopped-out run's
  # risk_at_entry should switch to (entry_price - stop_loss_price) *
  # multiplier * quantity, the real defined-risk distance, rather than
  # this premium-at-risk fallback. Until then, premium at risk is the
  # standard convention for a defined-risk long option position with no
  # stop (max loss on a long option is the premium paid) — real,
  # computable today for every closed run, and not a placeholder value.
  @doc """
  The `expectancy_r`/`lcb95`/`ucb95` R-multiple denominator for one
  entry fill — see this function's own `TODO` above for what it will
  become once automatic stop-loss exercise exists.
  """
  @spec compute_risk_at_entry(Decimal.t(), integer(), integer()) :: Decimal.t()
  def compute_risk_at_entry(entry_price, multiplier, quantity) do
    entry_price |> Decimal.mult(multiplier) |> Decimal.mult(quantity)
  end

  @churn_max_hold_time_seconds 90
  @churn_max_reopen_gap_seconds 120

  @doc """
  Flags the immediately-prior closed run for `{strategy_version_id,
  symbol}` as churn if `new_run` (just opened) is a flatten-and-reopen
  of it — held for under #{@churn_max_hold_time_seconds}s, then
  reopened within #{@churn_max_reopen_gap_seconds}s of that close.
  Mirrors `trading_system`'s own `maybe_mark_prior_run_as_churn/2`
  (confirmed by reading that function directly), scoped by `symbol`
  instead of `strategy_target_id` — this app has no separate targets
  table, one target-pool member's `symbol` is the closest equivalent.

  A no-op if no such prior run exists, or if it's already flagged (an
  already-churned run isn't re-marked, and doesn't cascade — only the
  ONE immediately-prior run is ever checked, matching the source
  implementation's own `limit(1)`).
  """
  @spec maybe_mark_prior_run_as_churn(String.t(), SimRun.t()) :: :ok
  def maybe_mark_prior_run_as_churn(strategy_version_id, %SimRun{} = new_run) do
    cutoff = DateTime.add(DateTime.utc_now(), -@churn_max_reopen_gap_seconds, :second)

    prior_run =
      SimRun
      |> where([r], r.strategy_version_id == ^strategy_version_id)
      |> where([r], r.symbol == ^new_run.symbol)
      |> where([r], r.status == "closed")
      |> where([r], r.id != ^new_run.id)
      |> where([r], not r.is_churn)
      |> where([r], not is_nil(r.exit_at) and r.exit_at >= ^cutoff)
      |> where(
        [r],
        not is_nil(r.entry_at) and
          fragment("EXTRACT(EPOCH FROM (? - ?))", r.exit_at, r.entry_at) <
            @churn_max_hold_time_seconds
      )
      |> order_by([r], desc: r.exit_at)
      |> limit(1)
      |> Repo.one()

    if prior_run do
      {:ok, _run} = prior_run |> SimRun.churn_changeset() |> Repo.update()
    end

    :ok
  end

  @doc """
  Closes `run` with no entry ever having been filled — no `SimFill` row
  is created (there's nothing to record a fill for), just
  `SimRun.close_without_entry_changeset/2` flipping `status`/`exit_at`/
  `exit_reason`. The one real caller is
  `SimActivator.deactivate/1`'s handling of a monitor that was still
  flat when it was stopped — see that function's own doc for why
  `trading_live` has no equivalent case to mirror here.
  """
  @spec close_run_without_entry(SimRun.t(), String.t()) ::
          {:ok, SimRun.t()} | {:error, Ecto.Changeset.t()}
  def close_run_without_entry(%SimRun{} = run, exit_reason) do
    run
    |> SimRun.close_without_entry_changeset(%{
      exit_at: DateTime.utc_now(),
      exit_reason: exit_reason
    })
    |> Repo.update()
  end

  def list_open_sim_runs(%StrategyVersion{id: strategy_version_id}) do
    SimRun
    |> where([r], r.strategy_version_id == ^strategy_version_id and r.status == "open")
    |> Repo.all()
  end

  @doc """
  The most recently closed `SimRun` for `version`/`symbol`, or `nil` if
  none exists — `StrategyVersionDetailLive`'s "last closed" summary for
  a member with no currently-open run. `nil` `exit_price`/`realized_pnl`
  (a run closed via `close_run_without_entry/2`, never filled) is a real
  outcome, not something this filters out — the caller decides how to
  render it.
  """
  @spec last_closed_sim_run(StrategyVersion.t(), String.t()) :: SimRun.t() | nil
  def last_closed_sim_run(%StrategyVersion{id: strategy_version_id}, symbol) do
    SimRun
    |> where(
      [r],
      r.strategy_version_id == ^strategy_version_id and r.symbol == ^symbol and
        r.status == "closed"
    )
    |> order_by([r], desc: r.exit_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Every `SimRun` across every strategy version, most-recently-opened
  first, optionally filtered to one `status` (`"open"` or `"closed"`) —
  the Runs page's data source. Preloads `strategy_version` (through to
  `strategy`) since every real use of this list needs to show which
  strategy/version a run belongs to, not just the run's own contract
  fields — and `:tags`, since the Runs page also renders per-run tag
  chips.
  """
  @spec list_sim_runs(String.t() | nil) :: [SimRun.t()]
  def list_sim_runs(status \\ nil) do
    SimRun
    |> maybe_filter_status(status)
    |> order_by([r], desc: r.inserted_at)
    |> preload([:tags, :sim_fills, strategy_version: :strategy])
    |> Repo.all()
  end

  @doc """
  Paginated `SimRun` listing for `/api/v1/runs` and the `list_sim_runs`
  MCP tool — same filtering/ordering/preloads as `list_sim_runs/1`, but
  bounded by `limit`/`offset` rather than returning every matching row
  unconditionally. `limit` is clamped to `@max_page_size` (100) so a
  caller can't force an unbounded query; `offset` defaults to `0`.
  Returns `{runs, total_count}` — `total_count` is the count of every
  matching row (ignoring `limit`/`offset`), so a caller can compute
  whether more pages remain without a second round trip.
  """
  @spec list_sim_runs_page(String.t() | nil, keyword()) :: {[SimRun.t()], non_neg_integer()}
  def list_sim_runs_page(status \\ nil, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> clamp_page_size()
    offset = max(Keyword.get(opts, :offset, 0), 0)

    base_query = SimRun |> maybe_filter_status(status)

    total_count = base_query |> select([r], count(r.id)) |> Repo.one()

    runs =
      base_query
      |> order_by([r], desc: r.inserted_at)
      |> limit(^limit)
      |> offset(^offset)
      |> preload([:tags, strategy_version: :strategy])
      |> Repo.all()

    {runs, total_count}
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [r], r.status == ^status)

  @max_page_size 100

  defp clamp_page_size(limit) when is_integer(limit) and limit > 0,
    do: min(limit, @max_page_size)

  defp clamp_page_size(_limit), do: 20

  @doc """
  Every currently-active `StrategyVersion` (`activated_at` set,
  `deactivated_at` nil — see those fields' own doc for why this is a
  durable flag rather than derived from `SimRun` state), preloaded with
  `:strategy` and its own currently-open runs (via the `:sim_runs`
  association, `:where`-scoped in the preload query rather than a
  second `list_open_sim_runs/1` round trip per version) — the Active
  Strategies page's data source.

  Also excludes `lifecycle_stage == "retired"` — `downgrade_strategy_version/3`
  only flips `lifecycle_stage`, it does not itself deactivate, so a
  version retired without first being deactivated would otherwise still
  show here as "active" on the page an operator lands on first.

  **Not** "has an open `SimRun`" — a version stays in this list while
  flat (its last position closed via a rule-triggered exit, watching
  for the next entry) exactly as long as while it holds an open
  position; `sim_runs` is simply `[]` for a flat-but-active version.
  Confirmed live 2026-09-15 this distinction matters: under the old
  "has an open run" definition, a version that went flat right before
  an app restart had its monitor silently and permanently lost (nothing
  marked it "still active" for `SimReactivator` to find), even though
  the operator never deactivated it.
  """
  @spec list_active_strategy_versions() :: [StrategyVersion.t()]
  def list_active_strategy_versions do
    StrategyVersion
    |> where(
      [v],
      not is_nil(v.activated_at) and is_nil(v.deactivated_at) and
        v.lifecycle_stage != "retired"
    )
    |> preload([:strategy, sim_runs: ^from(r in SimRun, where: r.status == "open")])
    |> Repo.all()
  end

  @doc """
  A `MapSet` of every currently-active `StrategyVersion.id` (same
  `activated_at`/`deactivated_at` definition as
  `list_active_strategy_versions/0`) — the cheap, single-query
  membership check `StrategyVersionsLive`'s activate/deactivate button
  needs per row, without paying `list_active_strategy_versions/0`'s own
  full preload cost when only a yes/no per row is needed.
  """
  @spec active_strategy_version_ids() :: MapSet.t(String.t())
  def active_strategy_version_ids do
    StrategyVersion
    |> where([v], not is_nil(v.activated_at) and is_nil(v.deactivated_at))
    |> select([v], v.id)
    |> Repo.all()
    |> MapSet.new()
  end

  def list_sim_fills(%SimRun{id: sim_run_id}) do
    SimFill
    |> where([f], f.sim_run_id == ^sim_run_id)
    |> order_by([f], asc: f.filled_at)
    |> Repo.all()
  end

  @doc """
  Sums every fill's `commission` for `run` — `nil` (never coerced to
  zero) if `run` has no fills yet, or if any fill's own `commission` is
  `nil` (not yet estimated, or predates this feature) — mirrors
  `trading_system`'s own `total_run_commission/1` (confirmed by reading
  its `Trading.close_run/3` directly): understating a run's real cost by
  silently treating an unknown commission as free is worse than just
  saying "unknown." Uses `run.sim_fills` directly when already preloaded
  (e.g. `list_sim_runs/1`'s own `:sim_fills` preload, for a page showing
  many runs at once) rather than always issuing its own query.
  """
  @spec total_run_commission(SimRun.t()) :: Decimal.t() | nil
  def total_run_commission(%SimRun{sim_fills: %Ecto.Association.NotLoaded{}} = run) do
    total_run_commission(%{run | sim_fills: list_sim_fills(run)})
  end

  def total_run_commission(%SimRun{} = run) do
    run.sim_fills
    |> case do
      [] ->
        nil

      fills ->
        if Enum.any?(fills, &is_nil(&1.commission)) do
          nil
        else
          Enum.reduce(fills, Decimal.new(0), &Decimal.add(&2, &1.commission))
        end
    end
  end

  @doc """
  Every closed `SimRun` for `version`, grouped by
  `context["regime_label"]` (see the `add_context_to_sim_runs`
  migration's own comment — `"regime_label"` is one of `context`'s
  first, exploratory keys, not yet a real column). A run with no
  `regime_label` (never captured, or `trading_signal` was unreachable at
  entry — see `ContractMonitor.entry_context/1`'s own doc) groups under
  the literal string `"uncategorized"`, a real, visible bucket key
  rather than a silently-dropped row — mirrors
  `TradingLive.PerformanceMetrics.expectancy_by_regime/1`'s identical
  choice (confirmed by reading that function directly).

  Grouping happens in Elixir after a full fetch, not a SQL `GROUP BY` —
  same choice `trading_live`'s own regime rollup makes at comparable
  data volumes (an unindexed JSON key isn't worth a `GROUP BY` until
  `regime_label` is promoted to its own column, per the migration's own
  note on when that's worth doing).
  """
  @spec closed_runs_by_regime(StrategyVersion.t()) :: %{String.t() => [SimRun.t()]}
  def closed_runs_by_regime(%StrategyVersion{id: strategy_version_id}) do
    SimRun
    |> where([r], r.strategy_version_id == ^strategy_version_id and r.status == "closed")
    |> Repo.all()
    |> Enum.group_by(&(&1.context["regime_label"] || "uncategorized"))
  end

  @doc """
  The `limit` most recent `SimFill`s across every `SimRun` belonging to
  `version`, most-recent-first, preloaded with `:sim_run` — a "recent
  fills" panel's data source (`StrategyVersionDetailLive`), showing
  every entry/exit fill for the version regardless of which target-pool
  member/contract it belongs to, not just whichever one the operator
  happens to be looking at. `SimFill` has no direct
  `strategy_version_id` of its own (it belongs to a `SimRun`, which
  belongs to the version), hence the join rather than a plain `where`.
  """
  @spec list_recent_fills_for_version(StrategyVersion.t(), pos_integer()) :: [SimFill.t()]
  def list_recent_fills_for_version(%StrategyVersion{id: strategy_version_id}, limit \\ 15) do
    SimFill
    |> join(:inner, [f], r in SimRun, on: f.sim_run_id == r.id)
    |> where([f, r], r.strategy_version_id == ^strategy_version_id)
    |> order_by([f], desc: f.filled_at)
    |> limit(^limit)
    |> preload([f, r], sim_run: r)
    |> Repo.all()
  end

  @doc """
  Total count of every `SimFill` across every `SimRun` belonging to
  `version` — pairs with `list_recent_fills_for_version/2`'s own
  `limit`-bounded list so the Recent Fills panel can show "N of TOTAL"
  rather than leaving the operator unable to tell whether the 15 shown
  are everything or just the most recent slice of a much longer history.
  """
  @spec count_fills_for_version(StrategyVersion.t()) :: non_neg_integer()
  def count_fills_for_version(%StrategyVersion{id: strategy_version_id}) do
    SimFill
    |> join(:inner, [f], r in SimRun, on: f.sim_run_id == r.id)
    |> where([f, r], r.strategy_version_id == ^strategy_version_id)
    |> select([f], count(f.id))
    |> Repo.one()
  end

  # --- Candidate metrics (Candidates page) -----------------------------------
  #
  # v1 of trading_system's own Trading.full_universe_version_metrics/2 +
  # CandidateGates, scaled to this app's much smaller data volume and
  # data model — see CandidateGates's own moduledoc for the full mapping
  # from trading_system's nine gates to this app's equivalents, and
  # Sim.compute_risk_at_entry/3's own doc for why expectancy_r here is a
  # real R-multiple (entry-premium-at-risk denominator) rather than a
  # placeholder.

  @candidate_lifecycle_stages ~w(discovery quarantine)

  @doc """
  One metrics row per non-deleted `discovery`/`quarantine`-stage
  `StrategyVersion` — everything `CandidateGates.evaluate/2` and
  `CandidatesLive` need, computed fresh from live `SimRun`/`SimFill`
  data on every call (deliberately NOT a `PerformanceSnapshot` read —
  that table is a once-daily historical rollup; a candidate-triage page
  needs current state). Mirrors `trading_system`'s own
  `full_universe_version_metrics/2` (confirmed by reading that function
  directly): one grouped SQL query for the statistical core
  (n/expectancy_r/lcb95/ucb95/realized_pnl, `is_churn`-excluded), then a
  handful of narrower per-version-id queries joined together in Elixir.

  No `limit`/`offset` — this app's version count is nowhere near
  `trading_system`'s ~900+, so returning the whole discovery+quarantine
  population in one call (matching that page's own `@fetch_limit: 5000`
  "just fetch everything" approach at its scale) needs no pagination
  here either.
  """
  @spec full_universe_version_metrics() :: [map()]
  def full_universe_version_metrics do
    versions =
      StrategyVersion
      |> where([v], is_nil(v.deleted_at))
      |> where([v], v.lifecycle_stage in @candidate_lifecycle_stages)
      |> preload([:strategy, :tags, :target_pool])
      |> Repo.all()

    version_ids = Enum.map(versions, & &1.id)
    stats_by_id = expectancy_r_stats_by_version(version_ids)
    commission_by_id = avg_commission_by_version(version_ids)
    exit_histogram_by_id = exit_reason_histogram_by_version(version_ids)
    last_traded_by_id = last_traded_on_by_version(version_ids)
    excluded_by_id = excluded_run_stats_by_version(version_ids)

    Enum.map(versions, fn version ->
      stats =
        Map.get(stats_by_id, version.id, %{
          n_closes: 0,
          expectancy_r: nil,
          lcb95: nil,
          ucb95: nil,
          realized_pnl: nil
        })

      excluded = Map.get(excluded_by_id, version.id, %{count: 0, pnl: Decimal.new(0)})
      avg_commission = Map.get(commission_by_id, version.id)

      %{
        strategy_version_id: version.id,
        strategy_id: version.strategy_id,
        strategy_name: version.strategy.name,
        version: version.version,
        lifecycle_stage: version.lifecycle_stage,
        direction: version.direction,
        rules: version.rules,
        rating: version.rating,
        tags: version.tags,
        target_pool_id: version.target_pool_id,
        target_pool_name: version.target_pool && version.target_pool.name,
        quarantine_trading_days: version.quarantine_trading_days || 0,
        n_closes: stats.n_closes,
        expectancy_r: stats.expectancy_r,
        lcb95: stats.lcb95,
        ucb95: stats.ucb95,
        realized_pnl: stats.realized_pnl,
        avg_commission: avg_commission,
        cost_margin: cost_margin(stats.expectancy_r, avg_commission, stats.n_closes),
        exit_reason_histogram: Map.get(exit_histogram_by_id, version.id, %{}),
        excluded_count: excluded.count,
        excluded_pnl: excluded.pnl,
        last_traded_on: Map.get(last_traded_by_id, version.id)
      }
    end)
  end

  # n/expectancy_r/lcb95/ucb95/realized_pnl, grouped by strategy_version_id
  # — excludes is_churn runs and any run missing risk_at_entry (a run
  # closed via close_run_without_entry/2 never received an entry fill,
  # so it has no risk_at_entry, no entry_price, nothing to divide by;
  # same "closed but never traded" case this app already models
  # elsewhere).
  defp expectancy_r_stats_by_version(version_ids) do
    SimRun
    |> where([r], r.strategy_version_id in ^version_ids)
    |> where([r], r.status == "closed")
    |> where([r], not r.is_churn)
    |> where([r], not is_nil(r.realized_pnl_net))
    |> where([r], not is_nil(r.risk_at_entry) and r.risk_at_entry != 0)
    |> group_by([r], r.strategy_version_id)
    |> select([r], %{
      strategy_version_id: r.strategy_version_id,
      n: count(r.id),
      mean: avg(fragment("? / ?", r.realized_pnl_net, r.risk_at_entry)),
      stddev: fragment("stddev_samp(? / ?)", r.realized_pnl_net, r.risk_at_entry),
      realized_pnl: sum(r.realized_pnl_net)
    })
    |> Repo.all()
    |> Map.new(fn row ->
      stats =
        if row.n >= 2 and row.mean do
          stddev = row.stddev || Decimal.new(0)
          {lcb, ucb} = TradingCore.Stats.bounds(row.mean, stddev, row.n, :p95)

          %{
            expectancy_r: row.mean,
            lcb95: lcb && Decimal.to_float(lcb),
            ucb95: ucb && Decimal.to_float(ucb)
          }
        else
          %{expectancy_r: row.mean, lcb95: nil, ucb95: nil}
        end

      stats = Map.merge(stats, %{n_closes: row.n, realized_pnl: row.realized_pnl})
      {row.strategy_version_id, stats}
    end)
  end

  # This app's own cost basis for gate E/cost_margin — average REAL
  # estimated commission per closed run (TradingCore.Costs.IBKR, see
  # ContractMonitor.estimate_commission/3), expressed in R-units by
  # dividing through the same average risk_at_entry used for
  # expectancy_r, rather than trading_system's more complex required_r/
  # notional-slippage-estimate fallback — this app already has real
  # per-fill commission data, a more direct cost floor than an
  # estimated-slippage guess.
  defp avg_commission_by_version(version_ids) do
    SimRun
    |> where([r], r.strategy_version_id in ^version_ids)
    |> where([r], r.status == "closed")
    |> where([r], not r.is_churn)
    |> where([r], not is_nil(r.risk_at_entry) and r.risk_at_entry != 0)
    |> join(:inner, [r], f in SimFill, on: f.sim_run_id == r.id)
    |> where([r, f], not is_nil(f.commission))
    |> group_by([r], r.strategy_version_id)
    |> select([r, f], %{
      strategy_version_id: r.strategy_version_id,
      avg_commission_r: avg(fragment("? / ?", f.commission, r.risk_at_entry))
    })
    |> Repo.all()
    |> Map.new(fn row -> {row.strategy_version_id, row.avg_commission_r} end)
  end

  # Gate E's own basis: expectancy_r minus the average per-fill
  # commission (in R-units, summed across both legs) — nil (never
  # coerced to zero) whenever either input is missing, same
  # "understating cost by guessing is worse than saying unknown"
  # posture this module already uses elsewhere.
  defp cost_margin(nil, _avg_commission_r, _n_closes), do: nil
  defp cost_margin(_expectancy_r, nil, _n_closes), do: nil
  defp cost_margin(_expectancy_r, _avg_commission_r, 0), do: nil

  defp cost_margin(expectancy_r, avg_commission_r, _n_closes) do
    # avg_commission_r is per-fill; two fills (entry + exit) per closed
    # run, so double it for a whole-round-trip cost estimate.
    Decimal.sub(expectancy_r, Decimal.mult(avg_commission_r, 2))
  end

  defp exit_reason_histogram_by_version(version_ids) do
    SimRun
    |> where([r], r.strategy_version_id in ^version_ids)
    |> where([r], r.status == "closed")
    |> where([r], not r.is_churn)
    |> where([r], not is_nil(r.exit_reason))
    |> group_by([r], [r.strategy_version_id, r.exit_reason])
    |> select([r], {r.strategy_version_id, r.exit_reason, count(r.id)})
    |> Repo.all()
    |> Enum.group_by(fn {version_id, _reason, _count} -> version_id end)
    |> Map.new(fn {version_id, rows} ->
      {version_id, Map.new(rows, fn {_id, reason, count} -> {reason, count} end)}
    end)
  end

  defp last_traded_on_by_version(version_ids) do
    SimRun
    |> where([r], r.strategy_version_id in ^version_ids)
    |> where([r], r.status == "closed")
    |> where([r], not is_nil(r.exit_at))
    |> group_by([r], r.strategy_version_id)
    |> select([r], {r.strategy_version_id, max(r.exit_at)})
    |> Repo.all()
    |> Map.new()
  end

  # Churn + never-entered-fill exclusions, for the Churn column and
  # gate C's own denominator — mirrors expectancy_r_stats_by_version/1's
  # own is_churn filter, just counting the complement instead.
  defp excluded_run_stats_by_version(version_ids) do
    SimRun
    |> where([r], r.strategy_version_id in ^version_ids)
    |> where([r], r.status == "closed")
    |> where([r], r.is_churn)
    |> group_by([r], r.strategy_version_id)
    |> select([r], %{
      strategy_version_id: r.strategy_version_id,
      count: count(r.id),
      pnl: sum(r.realized_pnl_net)
    })
    |> Repo.all()
    |> Map.new(fn row ->
      {row.strategy_version_id, %{count: row.count, pnl: row.pnl || Decimal.new(0)}}
    end)
  end

  # --- Performance snapshots --------------------------------------------------
  #
  # v1 of trading_system's own StrategyPerformanceSnapshot, scaled down —
  # see PerformanceSnapshot's own moduledoc for what's ported and what's
  # deliberately deferred.

  @snapshot_lifecycle_stages ~w(discovery quarantine test_portfolio)

  @doc """
  Snapshots every non-deleted version currently in `discovery`,
  `quarantine`, or `test_portfolio` — `retired` is excluded (a retired
  version's track record doesn't change; there's nothing new to
  compute) — writing one `PerformanceSnapshot` row per version that has
  at least one closed run in its window (see `snapshot_version/2` — a
  version with none is a no-op, not an all-nil row). Called by
  `TradingOptionsSim.Sim.Workers.PerformanceSnapshotWorker`, same
  "delegator + counts" shape `trading_system`'s own
  `snapshot_all_active_versions/0` uses.
  """
  @spec snapshot_all_active_versions() :: %{
          snapshotted: non_neg_integer(),
          skipped: non_neg_integer()
        }
  def snapshot_all_active_versions do
    computed_at = DateTime.utc_now()

    StrategyVersion
    |> where([v], is_nil(v.deleted_at))
    |> where([v], v.lifecycle_stage in @snapshot_lifecycle_stages)
    |> Repo.all()
    |> Enum.reduce(%{snapshotted: 0, skipped: 0}, fn version, acc ->
      case snapshot_version(version, computed_at) do
        {:ok, _snapshot} -> Map.update!(acc, :snapshotted, &(&1 + 1))
        :ok -> Map.update!(acc, :skipped, &(&1 + 1))
      end
    end)
  end

  @doc """
  Computes and persists one `PerformanceSnapshot` for `version`, over
  `version.activated_at` (or `inserted_at`, if never activated) through
  `computed_at` — "this version's whole track record to date", the same
  cumulative-since-X window `trading_system`'s own
  `snapshot_version_mode/5` uses (confirmed by reading that function
  directly), not a single calendar day.

  A no-op (`:ok`, writes nothing) when there are no closed runs in that
  window — same choice `trading_system` makes, avoiding an all-nil row
  for a version that hasn't traded yet.
  """
  @spec snapshot_version(StrategyVersion.t(), DateTime.t()) ::
          {:ok, PerformanceSnapshot.t()} | :ok
  def snapshot_version(%StrategyVersion{} = version, computed_at \\ DateTime.utc_now()) do
    period_start = version.activated_at || version.inserted_at

    closed_runs =
      SimRun
      |> where([r], r.strategy_version_id == ^version.id and r.status == "closed")
      |> where([r], r.exit_at >= ^period_start)
      |> preload(:sim_fills)
      |> Repo.all()

    if closed_runs == [] do
      :ok
    else
      %PerformanceSnapshot{}
      |> PerformanceSnapshot.changeset(%{
        strategy_version_id: version.id,
        lifecycle_stage: version.lifecycle_stage,
        period_start: period_start,
        period_end: computed_at,
        computed_at: computed_at,
        n_trades: length(closed_runs),
        n_wins: Enum.count(closed_runs, &won?/1),
        n_losses: Enum.count(closed_runs, &(!won?(&1))),
        win_rate: win_rate(closed_runs),
        realized_pnl_gross: sum_decimal(closed_runs, & &1.realized_pnl),
        realized_pnl_net: sum_decimal_if_all_present(closed_runs, & &1.realized_pnl_net),
        total_commission: sum_decimal_if_all_present(closed_runs, &total_run_commission/1)
      })
      |> Repo.insert()
    end
  end

  defp won?(%SimRun{realized_pnl: nil}), do: false

  defp won?(%SimRun{realized_pnl: pnl}), do: Decimal.compare(pnl, Decimal.new(0)) == :gt

  # Only ever called with a non-empty list — snapshot_version/2's own
  # empty-list branch short-circuits to :ok before this is reached.
  defp win_rate(closed_runs) do
    wins = Enum.count(closed_runs, &won?/1)
    Decimal.div(Decimal.new(wins), Decimal.new(length(closed_runs)))
  end

  defp sum_decimal(items, fun) do
    Enum.reduce(items, Decimal.new(0), fn item, acc ->
      Decimal.add(acc, fun.(item) || Decimal.new(0))
    end)
  end

  # nil (never coerced to zero) if any item's own value is nil — same
  # "understating cost/pnl by guessing zero is worse than saying
  # unknown" posture total_run_commission/1 already uses.
  defp sum_decimal_if_all_present(items, fun) do
    values = Enum.map(items, fun)

    if Enum.any?(values, &is_nil/1) do
      nil
    else
      Enum.reduce(values, Decimal.new(0), &Decimal.add(&2, &1))
    end
  end

  @doc "Every `PerformanceSnapshot` for `version`, most-recent-first."
  @spec list_performance_snapshots(StrategyVersion.t()) :: [PerformanceSnapshot.t()]
  def list_performance_snapshots(%StrategyVersion{id: strategy_version_id}) do
    PerformanceSnapshot
    |> where([s], s.strategy_version_id == ^strategy_version_id)
    |> order_by([s], desc: s.period_end)
    |> Repo.all()
  end

  @doc """
  Live (never persisted) today-so-far stats for `version` — the
  `ActiveStrategiesLive` summary strip's data source, same fields
  `snapshot_version/2` computes (`n_trades`/`n_wins`/`n_losses`/
  `realized_pnl_gross`/`realized_pnl_net`/`total_commission`) but for
  "today" specifically rather than a version's whole
  `activated_at`-to-now history, mirroring `trading_live`'s own
  `performance_strip/1` ("today's fills," not cumulative). `nil` if no
  runs closed today yet — same "no data" state that component's own
  empty-state clause handles, rather than an all-zero row.
  """
  @spec today_stats_for_version(StrategyVersion.t()) :: map() | nil
  def today_stats_for_version(%StrategyVersion{} = version) do
    today_start = Date.utc_today() |> DateTime.new!(~T[00:00:00])

    closed_runs =
      SimRun
      |> where([r], r.strategy_version_id == ^version.id and r.status == "closed")
      |> where([r], r.exit_at >= ^today_start)
      |> preload(:sim_fills)
      |> Repo.all()

    if closed_runs == [] do
      nil
    else
      %{
        n_trades: length(closed_runs),
        n_wins: Enum.count(closed_runs, &won?/1),
        n_losses: Enum.count(closed_runs, &(!won?(&1))),
        fill_count: closed_runs |> Enum.map(&length(&1.sim_fills)) |> Enum.sum(),
        realized_pnl_gross: sum_decimal(closed_runs, & &1.realized_pnl),
        realized_pnl_net: sum_decimal_if_all_present(closed_runs, & &1.realized_pnl_net),
        total_commission: sum_decimal_if_all_present(closed_runs, &total_run_commission/1)
      }
    end
  end

  # --- API tokens -----------------------------------------------------------
  #
  # Backs both /api/v1 (TradingOptionsSimWeb.ApiAuthPlug) and this app's
  # MCP server — one token type for both surfaces, per
  # OPTIONS_SIM_ARCHITECTURE_PLAN.md §4a.

  @doc "Generates and persists a new `ApiToken`. Returns `{:ok, {raw_token, token}}` — `raw_token` is shown to the caller exactly once."
  @spec create_api_token(String.t(), [String.t()]) ::
          {:ok, {String.t(), ApiToken.t()}} | {:error, Ecto.Changeset.t()}
  def create_api_token(label, scopes) do
    {raw, changeset} = ApiToken.generate(label, scopes)

    case Repo.insert(changeset) do
      {:ok, token} -> {:ok, {raw, token}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Verifies a raw Bearer token string and, if valid, bumps `last_used_at` and returns the `ApiToken`."
  @spec verify_api_token(String.t()) :: {:ok, ApiToken.t()} | :error
  def verify_api_token(raw_token) do
    with {:ok, token} <- ApiToken.verify(raw_token) do
      token
      |> Ecto.Changeset.change(last_used_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update()
    end
  end

  def revoke_api_token(%ApiToken{} = token) do
    token
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
  end

  @doc "Lists every `ApiToken`, newest first. Includes revoked tokens (a management panel shows status, not just active ones)."
  @spec list_api_tokens() :: [ApiToken.t()]
  def list_api_tokens do
    ApiToken
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
  end

  def get_api_token!(id), do: Repo.get!(ApiToken, id)

  # --- Exchange hours (§5c) ---------------------------------------------

  @doc """
  `ExchangeTradingHours.close_before_minutes` for whichever session
  `exchange` maps to, or `nil` if unmapped. Deliberately NOT cached
  (unlike session-open checks, which go through
  `TradingOptionsSim.ExchangeSessionCache`) — mirrors
  `TradingLive.LiveTrading.get_close_before_minutes/1`'s identical
  uncached query, so an operator edit to this field takes effect on
  `TradingOptionsSim.EodCloser`'s very next tick, not after the cache's
  next periodic refresh. Called once per monitor per `EodCloser` tick,
  not on the hot evaluation path every `ContractMonitor` runs, so the
  extra query cost here is negligible next to the DB-pool-exhaustion
  risk session-open checks would carry if left uncached at tick
  frequency.
  """
  @spec get_close_before_minutes(String.t()) :: integer() | nil
  def get_close_before_minutes(exchange) do
    ExchangeSession
    |> where([es], es.exchange == ^exchange)
    |> join(:inner, [es], eth in assoc(es, :exchange_trading_hours))
    |> select([_es, eth], eth.close_before_minutes)
    |> Repo.one()
  end

  # --- Cron/Oban health (System Performance page) ---------------------------

  @cron_workers [
    TradingOptionsSim.Sim.Workers.QuarantineEligibilityWorker,
    TradingOptionsSim.Sim.Workers.PerformanceSnapshotWorker
  ]

  # Jobs sitting in one of these states are pending/stuck work, not
  # historical record — same list `trading_system`'s own
  # `oban_pending_job_count/0` uses.
  @stuck_job_states ~w(available scheduled retryable executing)

  @doc """
  One row per cron-scheduled worker (`config.exs`'s `Oban.Plugins.Cron`
  crontab — currently just `QuarantineEligibilityWorker`), each with its
  most recent `Oban.Job` (any state) and, separately, its most recent
  two successfully-`completed` jobs — so a caller can tell "ran recently
  but keeps failing" apart from "hasn't run at all," and can see the gap
  between the last two runs (a worker whose `last_success` looks recent
  can still be broken if `second_last_success` reveals the prior run was
  much earlier than the schedule implies). Ported from
  `TradingSystem.Trading.cron_worker_health/0` — same shape, same
  `Oban.Worker.to_string/1` requirement (not `Kernel.to_string/1`: Oban
  strips the `"Elixir."` prefix before writing `oban_jobs.worker`, so a
  bare `to_string/1` here would silently match nothing).
  """
  @spec cron_worker_health() :: [
          %{
            worker: module(),
            last_job: Oban.Job.t() | nil,
            last_success: Oban.Job.t() | nil,
            second_last_success: Oban.Job.t() | nil
          }
        ]
  def cron_worker_health do
    Enum.map(@cron_workers, fn worker ->
      worker_name = Oban.Worker.to_string(worker)

      last_job =
        Oban.Job
        |> where([j], j.worker == ^worker_name)
        |> order_by([j], desc: j.inserted_at)
        |> limit(1)
        |> Repo.one()

      [last_success, second_last_success] =
        case Oban.Job
             |> where([j], j.worker == ^worker_name and j.state == "completed")
             |> order_by([j], desc: j.completed_at)
             |> limit(2)
             |> Repo.all() do
          [first, second] -> [first, second]
          [first] -> [first, nil]
          [] -> [nil, nil]
        end

      %{
        worker: worker,
        last_job: last_job,
        last_success: last_success,
        second_last_success: second_last_success
      }
    end)
  end

  @doc "Count of Oban jobs currently available/scheduled/retryable/executing, across all queues."
  @spec oban_pending_job_count() :: non_neg_integer()
  def oban_pending_job_count do
    Oban.Job
    |> where([j], j.state in ^@stuck_job_states)
    |> Repo.aggregate(:count)
  end

  # Puts `value` under whichever key type `attrs` already uses (string or
  # atom) — `Ecto.Changeset.cast/3` raises on a map with BOTH string and
  # atom keys, which a plain `Map.put(attrs, :some_atom_key, value)` would
  # produce whenever the caller is a controller action (string-keyed
  # request params), even though every caller in this module that builds
  # attrs by hand (tests, fixtures) uses atom keys. Empty/all-numeric-key
  # maps default to atom, matching every existing atom-keyed caller.
  defp put_key(attrs, key, value) when is_map(attrs) do
    if Enum.any?(Map.keys(attrs), &is_binary/1) do
      Map.put(attrs, Atom.to_string(key), value)
    else
      Map.put(attrs, key, value)
    end
  end
end
