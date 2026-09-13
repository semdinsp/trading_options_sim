defmodule TradingOptionsSim.Sim.RunTag do
  @moduledoc "Bare join table between `SimRun` and `Tag` — see `Tag`'s own moduledoc."

  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "run_tags" do
    belongs_to :sim_run, TradingOptionsSim.Sim.SimRun
    belongs_to :tag, TradingOptionsSim.Sim.Tag

    timestamps(type: :utc_datetime_usec)
  end
end
