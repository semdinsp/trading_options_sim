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

  def create_strategy_version(%Strategy{} = strategy, attrs) do
    %StrategyVersion{}
    |> StrategyVersion.changeset(put_key(attrs, :strategy_id, strategy.id))
    |> Repo.insert()
  end

  def get_strategy_version!(id), do: Repo.get!(StrategyVersion, id)

  def list_strategy_versions_for_strategy(%Strategy{id: strategy_id}) do
    StrategyVersion
    |> where([v], v.strategy_id == ^strategy_id)
    |> order_by([v], asc: v.version)
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

  defp maybe_filter_lifecycle_stage(query, nil), do: query

  defp maybe_filter_lifecycle_stage(query, stage),
    do: where(query, [v], v.lifecycle_stage == ^stage)

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

  def get_sim_run!(id), do: Repo.get!(SimRun, id)

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

  def list_open_sim_runs(%StrategyVersion{id: strategy_version_id}) do
    SimRun
    |> where([r], r.strategy_version_id == ^strategy_version_id and r.status == "open")
    |> Repo.all()
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
    |> preload([:tags, strategy_version: :strategy])
    |> Repo.all()
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [r], r.status == ^status)

  @doc """
  Every `StrategyVersion` with at least one currently-open `SimRun`,
  preloaded with `:strategy` and its own open runs (via the
  `:sim_runs` association, `:where`-scoped in the preload query rather
  than a second `list_open_sim_runs/1` round trip per version) — the
  Active Strategies page's data source. A version's open runs are
  exactly the contracts with a live `ContractMonitor` running
  (`SimActivator.start_or_find_monitor/3` never opens a run without
  also starting, or finding already running, its monitor) — so this
  list doubles as "which strategies currently have a running monitor,"
  without touching the process `Registry` directly (a DB-backed view
  stays correct even mid-monitor-restart, where a Registry lookup
  could show a brief gap).
  """
  @spec list_active_strategy_versions() :: [StrategyVersion.t()]
  def list_active_strategy_versions do
    open_run_version_ids =
      SimRun
      |> where([r], r.status == "open")
      |> select([r], r.strategy_version_id)
      |> distinct(true)

    StrategyVersion
    |> where([v], v.id in subquery(open_run_version_ids))
    |> preload([:strategy, sim_runs: ^from(r in SimRun, where: r.status == "open")])
    |> Repo.all()
  end

  def list_sim_fills(%SimRun{id: sim_run_id}) do
    SimFill
    |> where([f], f.sim_run_id == ^sim_run_id)
    |> order_by([f], asc: f.filled_at)
    |> Repo.all()
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
