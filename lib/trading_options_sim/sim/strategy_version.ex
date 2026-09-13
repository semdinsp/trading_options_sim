defmodule TradingOptionsSim.Sim.StrategyVersion do
  @moduledoc """
  An immutable strategy version — reused shape from
  `TradingSystem.Trading.StrategyVersion`, adapted for options (see
  `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §2). `params`/`rules`/
  `usage_conditions`/`position_sizing`/`option_leg_config` are never
  mutated in place once created — tweaking a strategy means calling
  `changeset/2` again with a new `version` number, not updating an
  existing row.

  **Three lifecycle stages, not `trading_system`'s five**:
  `discovery -> quarantine -> test_portfolio`, plus terminal `retired`.
  No `live` stage — this app never places a real order (see plan §7).
  `test_portfolio` is this app's terminal "proven, ready to hand off"
  stage; going live is a link to `trading_live` (or an options-capable
  equivalent), not a stage advance — mirrors how `trading_system` treats
  a `trading_live` link as a marker rather than a `lifecycle_stage`
  change.

  **Link direction, corrected 2026-09-13** (see
  `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §4): the link is written by the
  *pulling* app (`trading_live`) calling this app's own
  `link_live_strategy`/`unlink_live_strategy` API, the same way
  `trading_live` itself calls `trading_system`'s `link_trading_live`/
  `unlink_trading_live` after building its own local record —
  mirroring `TradingSystem.Trading.StrategyVersion`'s own
  `trading_live_active`/`trading_live_strategy_id`/
  `trading_live_linked_at`/`trading_live_unlinked_at` fields exactly.
  `live_strategy_active` is a comparison-visibility label only — it
  never gates whether this app's own lifecycle logic picks a version
  up, same as `trading_system`'s `trading_live_active`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @directions ~w(long short)
  @lifecycle_stages ~w(discovery quarantine test_portfolio retired)
  @retired_reasons ~w(manual failed_quarantine abandoned)
  @sources ~w(native promoted_from_trading_system)

  @option_rights ~w(C P either)
  @expiry_selections ~w(fixed dte_target leaps)
  @strike_selections ~w(fixed_delta fixed_strike pct_otm)

  schema "strategy_versions" do
    field :version, :integer
    field :params, :map, default: %{}
    field :rules, :map, default: %{}
    field :usage_conditions, :map, default: %{}
    field :position_sizing, :map
    field :direction, :string, default: "long"

    field :option_leg_config, :map, default: %{}

    field :lifecycle_stage, :string, default: "discovery"
    field :quarantine_started_at, :utc_datetime
    field :quarantine_trading_days, :integer, default: 0
    field :quarantine_last_counted_date, :date
    field :retired_reason, :string

    field :live_strategy_app, :string
    field :live_strategy_id, :binary_id
    field :live_strategy_active, :boolean, default: false
    field :live_linked_at, :utc_datetime_usec
    field :live_unlinked_at, :utc_datetime

    field :generation, :integer, default: 0

    field :source, :string, default: "native"
    field :source_trading_system_version_id, :binary_id
    field :promoted_at, :utc_datetime
    field :promoted_snapshot, :map

    field :notes, :string
    field :rating, :integer
    field :deleted_at, :utc_datetime

    belongs_to :strategy, TradingOptionsSim.Sim.Strategy
    belongs_to :parent_version, __MODULE__, foreign_key: :parent_version_id
    belongs_to :target_pool, TradingOptionsSim.Sim.TargetPool

    many_to_many :tags, TradingOptionsSim.Sim.Tag,
      join_through: TradingOptionsSim.Sim.StrategyVersionTag,
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc "The full set of valid `lifecycle_stage` values, in stage order."
  @spec lifecycle_stages() :: [String.t()]
  def lifecycle_stages, do: @lifecycle_stages

  @doc "The full set of valid `direction` values."
  @spec directions() :: [String.t()]
  def directions, do: @directions

  @doc "The full set of valid `retired_reason` values."
  @spec retired_reasons() :: [String.t()]
  def retired_reasons, do: @retired_reasons

  @doc """
  Builds a new strategy version. Never mutated in place once created —
  tweaking a strategy means calling this again with a new `version`
  number. `parent_version_id`/`generation` are lineage, set together by
  a future `fork_strategy_version/2` for a forked version.
  """
  def changeset(strategy_version, attrs) do
    strategy_version
    |> cast(attrs, [
      :strategy_id,
      :version,
      :params,
      :rules,
      :usage_conditions,
      :position_sizing,
      :direction,
      :option_leg_config,
      :parent_version_id,
      :generation,
      :target_pool_id,
      :source,
      :source_trading_system_version_id,
      :promoted_at,
      :promoted_snapshot
    ])
    |> validate_required([:strategy_id, :version, :position_sizing])
    |> validate_inclusion(:direction, @directions)
    |> validate_inclusion(:source, @sources)
    |> validate_number(:generation, greater_than_or_equal_to: 0)
    |> validate_option_leg_config()
    |> unique_constraint([:strategy_id, :version])
    |> foreign_key_constraint(:parent_version_id)
    |> foreign_key_constraint(:target_pool_id)
    |> foreign_key_constraint(:strategy_id)
  end

  @doc """
  Same "deliberate exception, no lifecycle-stage guard" shape as
  `trading_system`'s `rating_changeset/2` — an operator judgment applied
  after a version exists, not part of its trading logic.
  """
  def rating_changeset(strategy_version, attrs) do
    strategy_version
    |> cast(attrs, [:rating])
    |> validate_number(:rating, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
  end

  @doc "Same deliberate-exception shape as `rating_changeset/2` — notes are revisable commentary."
  def notes_changeset(strategy_version, attrs) do
    cast(strategy_version, attrs, [:notes])
  end

  @doc """
  The lifecycle-stage transition changeset — see this module's own
  moduledoc for the three-stage state machine and
  `TradingOptionsSim.Sim.promote_strategy_version/2`/
  `downgrade_strategy_version/3` for the only callers. Deliberately
  separate from `changeset/2`'s cast list, same reasoning as
  `trading_system`'s own `lifecycle_stage_changeset/2`.
  """
  def lifecycle_stage_changeset(strategy_version, attrs) do
    strategy_version
    |> cast(attrs, [
      :lifecycle_stage,
      :quarantine_started_at,
      :quarantine_trading_days,
      :quarantine_last_counted_date,
      :retired_reason
    ])
    |> validate_inclusion(:lifecycle_stage, @lifecycle_stages)
    |> validate_number(:quarantine_trading_days, greater_than_or_equal_to: 0)
    |> validate_inclusion(:retired_reason, @retired_reasons)
  end

  @doc """
  Records a link to a `live_strategy_app`'s own strategy record —
  `lifecycle_stage` stays `test_portfolio`, same "marker, not a stage
  advance" pattern `trading_system.promote_strategy_version(version,
  "live")` uses for `trading_live_linked_at`. Called by
  `Sim.link_live_strategy/3`, which the pulling app's own promotion flow
  invokes after it has already built its local record — see plan §4.
  """
  def link_live_strategy_changeset(strategy_version, attrs) do
    cast(strategy_version, attrs, [
      :live_strategy_app,
      :live_strategy_id,
      :live_strategy_active,
      :live_linked_at
    ])
  end

  @doc """
  Unlinks from `live_strategy_app` — called when that app kills/deletes/
  unpromotes the strategy it was linked to. Sets `live_strategy_active:
  false` and `live_unlinked_at`; **deliberately leaves
  `live_strategy_app`/`live_strategy_id`/`live_linked_at` alone** so the
  version's link history stays visible, mirroring
  `TradingSystem.Trading.StrategyVersion.trading_live_link_changeset/2`'s
  own doc for why unlinking never erases history.
  """
  def unlink_live_strategy_changeset(strategy_version, attrs) do
    cast(strategy_version, attrs, [:live_strategy_active, :live_unlinked_at])
  end

  defp validate_option_leg_config(changeset) do
    case get_field(changeset, :option_leg_config) do
      nil ->
        changeset

      config when config == %{} ->
        changeset

      config ->
        changeset
        |> validate_leg_config_field(config, "right", @option_rights)
        |> validate_leg_config_field(config, "expiry_selection", @expiry_selections)
        |> validate_leg_config_field(config, "strike_selection", @strike_selections)
    end
  end

  defp validate_leg_config_field(changeset, config, key, allowed) do
    case Map.get(config, key) do
      nil ->
        changeset

      value ->
        if value in allowed do
          changeset
        else
          add_error(
            changeset,
            :option_leg_config,
            "#{key} must be one of #{Enum.join(allowed, ", ")}, got #{inspect(value)}"
          )
        end
    end
  end
end
