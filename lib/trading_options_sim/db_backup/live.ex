defmodule TradingOptionsSim.DbBackup.Live do
  @moduledoc "Real `TradingOptionsSim.DbBackup` adapter — delegates straight to `TradingCore.DbBackup.dump/3`."

  @behaviour TradingOptionsSim.DbBackup

  @impl true
  def dump(repo_config, dir), do: TradingCore.DbBackup.dump(repo_config, dir)
end
