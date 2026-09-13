defmodule TradingOptionsSim.Sim.StrategyVersionTag do
  @moduledoc "Bare join table between `StrategyVersion` and `Tag` — see `Tag`'s own moduledoc."

  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "strategy_version_tags" do
    belongs_to :strategy_version, TradingOptionsSim.Sim.StrategyVersion
    belongs_to :tag, TradingOptionsSim.Sim.Tag

    timestamps(type: :utc_datetime_usec)
  end
end
