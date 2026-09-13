defmodule TradingOptionsSim.MCP.TokenValidator do
  @moduledoc """
  Adapts `TradingOptionsSim.Sim.ApiToken.verify/1` into
  `Anubis.Server.Authorization.Validator`'s behaviour, so
  `TradingOptionsSim.MCP.Server`'s bearer-token auth is backed by the
  same local token store the Settings page manages — ported from
  `TradingSystem.MCP.TokenValidator`/`TradingLive.MCP.TokenValidator`'s
  identical pattern. See `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §4a.
  """

  require Logger

  @behaviour Anubis.Server.Authorization.Validator

  alias TradingOptionsSim.Sim.ApiToken

  @impl true
  def validate_token(raw_token, config) do
    case ApiToken.verify(raw_token) do
      {:ok, token} ->
        Logger.info("MCP auth: accepted token id=#{token.id} label=#{inspect(token.label)}")
        {:ok, %{"sub" => token.id, "scopes" => token.scopes, "aud" => config.resource}}

      :error ->
        Logger.warning("MCP auth: rejected token (invalid, expired, or revoked)")
        {:error, :invalid_token}
    end
  end
end
