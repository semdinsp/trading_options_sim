defmodule TradingOptionsSim.MCP.Tools.CreateStrategyVersion do
  @moduledoc """
  Creates a new `StrategyVersion` under `strategy_id` — the same
  `TradingOptionsSim.Sim.create_strategy_version/2` call
  `POST /api/v1/strategies/:id/versions` uses. Closes a real gap:
  `create_strategy` (MCP) only ever creates the bare `Strategy` row —
  no rules, no position sizing, nothing tradeable — and until this
  tool, no MCP tool created a `StrategyVersion` at all, so an MCP
  client could create a strategy but never actually give it anything
  to trade.

  `version` is required, no auto-increment — this app tracks version
  numbers explicitly (see `StrategyVersion.changeset/2`'s own
  `validate_required/2`), same as the REST endpoint; the caller decides
  the next number (typically 1 for a brand-new strategy).

  New versions always start in `lifecycle_stage: "discovery"`
  (`StrategyVersion`'s own schema default) — promotion is a separate
  step (`promote_version`), not something this tool accepts, mirroring
  `CreateStrategy`'s own "no lifecycle shortcuts at creation" posture.

  `rules`/`option_leg_config`/`target_pool_id` are all optional at
  creation (a version can exist before any of them are set — see
  `SimActivator.activate/1`'s own `:no_target_pool`/
  `:unsupported_leg_config` error clauses for what happens if you try
  to activate one that's missing them) — but a version with no rules
  set will never actually enter a position once activated, since
  `TradingCore.RuleEngine.evaluate/2` treats a `nil`/empty rule as
  vacuously true only for a rule tree that's genuinely absent, not a
  substitute for a real entry condition.

  Requires the `"mcp:write"` scope — this creates persistent trading
  state. Rate-limited per token via `CallGuard.rate_limited?/2`.
  """

  use Anubis.Server.Component, type: :tool, scopes: ["mcp:write"]

  alias Anubis.MCP.Error
  alias Anubis.Server.{Frame, Response}
  alias TradingOptionsSim.MCP.CallGuard
  alias TradingOptionsSim.Sim

  schema do
    field :strategy_id, :string,
      required: true,
      description: "Strategy UUID to create the version under"

    field :version, :integer,
      required: true,
      description:
        "Version number — no auto-increment; the caller tracks numbering (typically 1 for a new strategy)"

    field :position_sizing, :map,
      required: false,
      description:
        "{\"method\": \"fixed_qty\", \"qty\": 1} or similar. Defaults to fixed_qty at 1 contract if omitted."

    field :direction, :string,
      required: false,
      description:
        "\"long\" or \"short\" — defaults to \"long\" (StrategyVersion's own schema default) if omitted"

    field :rules, :map,
      required: false,
      description:
        "{\"entry\": {...}, \"exit\": {...}} rule trees evaluated by TradingCore.RuleEngine. " <>
          "Omitting this creates a version that will never enter a position once activated."

    field :option_leg_config, :map,
      required: false,
      description:
        "v1 only supports fixed strike/expiry selection, e.g. " <>
          "{\"expiry_selection\": \"fixed\", \"fixed_expiry\": \"20271231\", " <>
          "\"strike_selection\": \"fixed_strike\", \"fixed_strike\": \"150.00\", \"right\": \"C\"} " <>
          "— required before this version can be activated (see SimActivator.activate/1's own " <>
          ":unsupported_leg_config error), but not required to create the version itself."

    field :target_pool_id, :string,
      required: false,
      description:
        "TargetPool UUID this version trades against — required before this version can be activated, not to create it"

    field :usage_conditions, :map,
      required: false,
      description: "Optional gating conditions, if any"
  end

  @impl true
  def execute(params, frame) do
    identity = Frame.subject(frame) || "anonymous"

    if CallGuard.rate_limited?(identity, "create_strategy_version") do
      {:error, Error.execution("rate limit exceeded for create_strategy_version"), frame}
    else
      case CallGuard.run(fn -> create(params) end) do
        {:error, :timeout} ->
          {:error, Error.execution("timed out creating strategy version"), frame}

        {:error, :not_found} ->
          {:error, Error.execution("no strategy with id #{params.strategy_id}"), frame}

        {:error, changeset} ->
          {:error,
           Error.execution("failed to create strategy version: #{inspect(changeset.errors)}"),
           frame}

        body ->
          {:reply, Response.json(Response.tool(), body), frame}
      end
    end
  end

  defp create(%{strategy_id: strategy_id, version: version} = params) do
    strategy = Sim.get_strategy!(strategy_id)

    attrs =
      params
      |> Map.take([
        :position_sizing,
        :direction,
        :rules,
        :option_leg_config,
        :target_pool_id,
        :usage_conditions
      ])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.put(:version, version)
      |> Map.put_new(:position_sizing, %{"method" => "fixed_qty", "qty" => 1})

    case Sim.create_strategy_version(strategy, attrs) do
      {:ok, version} ->
        %{
          id: version.id,
          strategy_id: version.strategy_id,
          version: version.version,
          direction: version.direction,
          lifecycle_stage: version.lifecycle_stage,
          rules: version.rules,
          position_sizing: version.position_sizing,
          option_leg_config: version.option_leg_config,
          target_pool_id: version.target_pool_id
        }

      {:error, changeset} ->
        {:error, changeset}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.Query.CastError -> {:error, :not_found}
  end
end
