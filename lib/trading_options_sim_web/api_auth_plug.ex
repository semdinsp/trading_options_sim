defmodule TradingOptionsSimWeb.ApiAuthPlug do
  @moduledoc """
  Bearer-token auth for `/api/v1` — checked before every API route. Never
  conflates "no such token" with "token exists but lacks the scope this
  route needs": a missing/invalid/expired/revoked token is `401`, a
  valid token missing the required scope is `403` — collapsing those
  into one response code would let a caller probing with guessed tokens
  learn whether a given token string is real from the response alone.

  Ported from `TradingSystemWeb.ApiAuthPlug` — same contract, same
  reasoning. See `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §4a.

  Usage: `plug TradingOptionsSimWeb.ApiAuthPlug, scope: "strategies:write"`.
  """

  import Plug.Conn
  alias TradingOptionsSim.Sim

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    required_scope = Keyword.fetch!(opts, :scope)

    with {:ok, raw_token} <- extract_bearer_token(conn),
         {:ok, token} <- Sim.verify_api_token(raw_token) do
      if required_scope in token.scopes do
        assign(conn, :api_token, token)
      else
        halt_with(conn, 403, "forbidden", "token does not have the \"#{required_scope}\" scope")
      end
    else
      _missing_or_invalid ->
        halt_with(conn, 401, "unauthorized", "missing or invalid bearer token")
    end
  end

  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _other -> :error
    end
  end

  defp halt_with(conn, status, error, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"error" => error, "message" => message}))
    |> halt()
  end
end
