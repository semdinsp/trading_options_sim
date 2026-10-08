defmodule TradingOptionsSim.MCP.Tools.ForkVersion do
  @moduledoc """
  Forks a strategy version into a new Strategy at version 1, copying
  everything not named in the request: direction, rules, option leg
  config, position sizing, `params` (including `params.risk_controls`),
  usage conditions, target pool, `overnight_hold` and
  `trading_hours_policy`. `create_strategy_version` can't carry `params`
  or the trading-hours fields, so it can't make a faithful copy; this
  can. Backed by `TradingOptionsSim.VersionFork.fork/2`, the same path
  as `POST /api/v1/versions/:id/fork`. Modelled on trading_system's
  `fork_version`.

  Requires the `"mcp:write"` scope. Rate-limited per token via
  `CallGuard.rate_limited?/2`.
  """

  use Anubis.Server.Component, type: :tool, scopes: ["mcp:write"]

  alias Anubis.MCP.Error
  alias Anubis.Server.{Frame, Response}
  alias TradingOptionsSim.MCP.CallGuard
  alias TradingOptionsSim.VersionFork
  alias TradingOptionsSimWeb.Api.Serializer

  @impl true
  def description do
    """
    Fork a strategy version into a NEW strategy (version 1, discovery stage, inactive unless activate is true). Everything not named here is copied exactly from the source: direction, rules, option_leg_config, position_sizing, params (including params.risk_controls stop-loss/take-profit and exit_strategy), usage_conditions, target_pool_id, overnight_hold, trading_hours_policy, and the operator's entry_delay_minutes (min delay) override. The source version is not modified.

    Change the rules in ONE of two ways (not both):
    - entry_gate: a rule tree AND-ed onto the source's entry rule, so the new entry is {"all": [<source entry>, <entry_gate>]}. The exit rule is never touched.
    - rules: a full replacement {"entry": ..., "exit": ...}.

    The resulting rules are validated like create_strategy_version (supported ops: gt, gte, lt, lte, eq, ne; transition ops are rejected), and every signal name must be a monitor key (run_*, regime_*) or a signal trading_signal knows (a slug or "definition:<uuid>"); unknown names are rejected.

    notes: what changed and why; "Forked from <source id> (<source name>)." is appended automatically. tags: tag names to add. Returns the new strategy_id, version_id and the full resolved config, including params.
    """
  end

  schema do
    field :version_id, :string, required: true, description: "Source StrategyVersion UUID"

    field :name, :string,
      required: true,
      description: "Name for the new Strategy, e.g. \"<source name> [Gate: Calm Vol]\""

    field :entry_gate, :map,
      required: false,
      description:
        "Rule tree AND-ed onto the source entry: new entry = {\"all\": [source_entry, entry_gate]}. Exit unchanged. Exclusive with rules."

    field :rules, :map,
      required: false,
      description: "Full replacement {\"entry\": ..., \"exit\": ...}. Exclusive with entry_gate."

    field :notes, :string,
      required: false,
      description: "Hypothesis and the one change made; the fork stamp is appended."

    field :tags, {:list, :string}, required: false, description: "Tag names to add"

    field :activate, :boolean,
      required: false,
      description: "Start monitors right away (same as activate_version). Default false."
  end

  @impl true
  def execute(params, frame) do
    identity = Frame.subject(frame) || "anonymous"

    if CallGuard.rate_limited?(identity, "fork_version") do
      {:error, Error.execution("rate limit exceeded for fork_version"), frame}
    else
      opts = Map.take(params, [:name, :entry_gate, :rules, :notes, :tags, :activate])

      case CallGuard.run(fn -> VersionFork.fork(params.version_id, opts) end) do
        {:error, :timeout} ->
          {:error, Error.execution("timed out forking version #{params.version_id}"), frame}

        {:error, reason} ->
          {:error, Error.execution(VersionFork.describe_error(reason)), frame}

        {:ok, result} ->
          {:reply, Response.json(Response.tool(), Serializer.version_fork(result)), frame}
      end
    end
  end
end
