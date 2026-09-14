defmodule TradingOptionsSim.DbBackup do
  @moduledoc """
  Config-swappable adapter over `TradingCore.DbBackup` (the sibling
  `trading_core` library's `pg_dump`-shelling-out module) — same pattern
  as `TradingSystem.DbBackup`/this app's own `SignalBus`: `SettingsLive`'s
  "Database Backup" panel calls only the functions here, never
  `TradingCore.DbBackup` directly, so tests stub via
  `TradingOptionsSim.DbBackup.Test` instead of actually shelling out to
  `pg_dump`.
  """

  @callback dump(repo_config :: keyword(), dir :: Path.t()) ::
              {:ok, path :: String.t()} | {:error, term()}

  @doc "Dumps `repo_config`'s database to `dir` — see `TradingCore.DbBackup.dump/3` for the full contract (format, timeout, PGPASSWORD handling)."
  @spec dump(keyword(), Path.t()) :: {:ok, String.t()} | {:error, term()}
  def dump(repo_config, dir), do: impl().dump(repo_config, dir)

  defp impl, do: Application.get_env(:trading_options_sim, :db_backup_adapter, __MODULE__.Live)
end
