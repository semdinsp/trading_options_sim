defmodule TradingOptionsSim.Sim.ExchangeSession do
  @moduledoc """
  Maps a `TargetPoolMember.exchange` string (e.g. `"NASDAQ"`) to the
  `ExchangeTradingHours` row it trades under — mirrors `trading_live`'s
  identically-named schema exactly. Local, editable settings data.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "exchange_sessions" do
    field :exchange, :string

    belongs_to :exchange_trading_hours, TradingOptionsSim.Sim.ExchangeTradingHours

    timestamps(type: :utc_datetime)
  end

  def changeset(exchange_session, attrs) do
    exchange_session
    |> cast(attrs, [:exchange, :exchange_trading_hours_id])
    |> validate_required([:exchange, :exchange_trading_hours_id])
    |> unique_constraint(:exchange)
    |> foreign_key_constraint(:exchange_trading_hours_id)
  end
end
