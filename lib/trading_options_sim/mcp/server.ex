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

  Six read-only tools, no scopes requirement — a valid, non-revoked
  token of any scope can call them: `list_strategies`, `get_strategy`,
  `list_target_pools`, `get_target_pool`, `list_tags`.

  Five write tools, each requiring `"mcp:write"`:
  `create_strategy`, `promote_version`, `downgrade_version`,
  `add_strategy_version_tag`.

  All ten reuse `CallGuard.rate_limited?/2`'s per-token-and-tool bucket
  (45 calls/60s) for the write tools, and `CallGuard.run/1`'s bounded
  timeout for every tool.
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
  component(TradingOptionsSim.MCP.Tools.ListTargetPools)
  component(TradingOptionsSim.MCP.Tools.GetTargetPool)
  component(TradingOptionsSim.MCP.Tools.ListTags)
  component(TradingOptionsSim.MCP.Tools.CreateStrategy)
  component(TradingOptionsSim.MCP.Tools.PromoteVersion)
  component(TradingOptionsSim.MCP.Tools.DowngradeVersion)
  component(TradingOptionsSim.MCP.Tools.ActivateVersion)
  component(TradingOptionsSim.MCP.Tools.DeactivateVersion)
  component(TradingOptionsSim.MCP.Tools.AddStrategyVersionTag)

  @impl true
  def init(_client_info, frame) do
    {:ok, frame}
  end
end
