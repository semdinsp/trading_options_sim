defmodule TradingOptionsSim.Sim do
  @moduledoc """
  The Sim context — strategies, versions, lifecycle transitions, target
  pools, and tags. See `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §2/§3/§3a.
  """

  import Ecto.Query

  alias TradingOptionsSim.Repo

  alias TradingOptionsSim.Sim.{
    ApiToken,
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
