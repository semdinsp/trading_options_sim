defmodule TradingOptionsSim.MCP.Server do
  @moduledoc """
  MCP (Model Context Protocol) server exposing strategies/versions/target
  pools/tags to any MCP client (Claude Desktop, Claude Code, another
  agent session) as callable tools — mounted at `/mcp` (see
  `TradingOptionsSimWeb.Router`), authenticated by
  `TradingOptionsSim.Sim.ApiToken` via
  `TradingOptionsSim.MCP.TokenValidator`. Mirrors
  `TradingSystem.MCP.Server`/`TradingLive.MCP.Server`'s architecture —
  see those moduledocs for the fuller rationale. See
  `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §4a for the initial tool set this
  ports.

  ## Tools and scope

  Read-only, no scope requirement — a valid, non-revoked token of any
  scope can call them: `list_strategies`, `get_strategy`,
  `list_strategy_versions`, `list_target_pools`, `get_target_pool`,
  `list_tags`.

  Read-only, requiring `"runs:read"` (matching the REST
  `GET /api/v1/runs` endpoint's own scope): `list_sim_runs`.

  Write tools, each requiring `"mcp:write"`: `create_strategy`,
  `create_strategy_version`, `promote_version`, `downgrade_version`,
  `activate_version`, `deactivate_version`, `add_strategy_version_tag`,
  `update_strategy_version_notes`.

  Every write tool reuses `CallGuard.rate_limited?/2`'s per-token-and-tool
  bucket (45 calls/60s); every tool (read or write) uses
  `CallGuard.run/1`'s bounded timeout.
  """

  @mcp_resource_url (
                      host = System.get_env("PHX_HOST") || "localhost"
                      scheme = if host == "localhost", do: "http", else: "https"
                      "#{scheme}://#{host}/mcp"
                    )

  use Anubis.Server,
    name: "trading_options_sim",
    version: "1.0.0",
    capabilities: [:tools],
    authorization: [
      authorization_servers: [@mcp_resource_url],
      resource: @mcp_resource_url,
      realm: "trading_options_sim",
      scopes_supported: ["mcp:read", "mcp:write"],
      validator: {TradingOptionsSim.MCP.TokenValidator, []}
    ]

  component(TradingOptionsSim.MCP.Tools.ListStrategies)
  component(TradingOptionsSim.MCP.Tools.GetStrategy)
  component(TradingOptionsSim.MCP.Tools.ListStrategyVersions)
  component(TradingOptionsSim.MCP.Tools.ListSimRuns)
  component(TradingOptionsSim.MCP.Tools.ListTargetPools)
  component(TradingOptionsSim.MCP.Tools.GetTargetPool)
  component(TradingOptionsSim.MCP.Tools.ListTags)
  component(TradingOptionsSim.MCP.Tools.CreateStrategy)
  component(TradingOptionsSim.MCP.Tools.CreateStrategyVersion)
  component(TradingOptionsSim.MCP.Tools.PromoteVersion)
  component(TradingOptionsSim.MCP.Tools.DowngradeVersion)
  component(TradingOptionsSim.MCP.Tools.ActivateVersion)
  component(TradingOptionsSim.MCP.Tools.DeactivateVersion)
  component(TradingOptionsSim.MCP.Tools.AddStrategyVersionTag)
  component(TradingOptionsSim.MCP.Tools.UpdateStrategyVersionNotes)

  @impl true
  def init(_client_info, frame) do
    {:ok, frame}
  end
end
