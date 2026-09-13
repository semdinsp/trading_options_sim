defmodule TradingOptionsSim.Sim do
  @moduledoc """
  The Sim context — strategies, versions, lifecycle transitions, target
  pools, and tags. See `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §2/§3/§3a.
  """

  import Ecto.Query

  alias TradingOptionsSim.Repo
  alias TradingOptionsSim.Sim.{Strategy, StrategyVersion, Tag, TargetPool, TargetPoolMember}

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
    |> StrategyVersion.changeset(Map.put(attrs, :strategy_id, strategy.id))
    |> Repo.insert()
  end

  def get_strategy_version!(id), do: Repo.get!(StrategyVersion, id)

  def list_strategy_versions_for_strategy(%Strategy{id: strategy_id}) do
    StrategyVersion
    |> where([v], v.strategy_id == ^strategy_id)
    |> order_by([v], asc: v.version)
    |> Repo.all()
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
  Stamps the outbound promote-to-live-app marker on a `test_portfolio`-
  stage version — `lifecycle_stage` stays `test_portfolio`. See
  `StrategyVersion.promote_to_live_app_changeset/2`'s own doc.
  """
  @spec promote_to_live_app(StrategyVersion.t(), String.t(), String.t()) ::
          {:ok, StrategyVersion.t()}
          | {:error, :invalid_transition}
          | {:error, Ecto.Changeset.t()}
  def promote_to_live_app(
        %StrategyVersion{lifecycle_stage: "test_portfolio"} = version,
        live_app,
        live_strategy_id
      ) do
    version
    |> StrategyVersion.promote_to_live_app_changeset(%{
      "promoted_to_live_app" => live_app,
      "promoted_to_live_strategy_id" => live_strategy_id,
      "promoted_to_live_at" => DateTime.utc_now()
    })
    |> Repo.update()
  end

  def promote_to_live_app(%StrategyVersion{}, _live_app, _live_strategy_id) do
    {:error, :invalid_transition}
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
    |> TargetPoolMember.changeset(Map.put(attrs, :target_pool_id, pool.id))
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
end
