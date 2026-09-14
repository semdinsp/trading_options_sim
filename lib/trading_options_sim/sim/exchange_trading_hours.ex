defmodule TradingOptionsSim.Sim.ExchangeTradingHours do
  @moduledoc """
  A named market session window (e.g. "US") — local, editable settings
  data, mirroring `trading_live`'s `ExchangeTradingHours`/`trading_system`'s
  `MarketHour` schemas exactly, per `OPTIONS_SIM_ARCHITECTURE_PLAN.md`
  §5c: independent per-app session data, sharing the exact same
  incident-hardened time-math via `TradingCore.MarketHours`. This app has
  no `ManualMarketHoliday` equivalent for v1 (see that section) —
  `to_session/1` always builds an empty `extra_holidays` list.

  `close_before_minutes` (11 by default, same as `trading_live`'s) is
  this app's own field, read directly by `TradingOptionsSim.EodCloser` —
  deliberately NOT part of `to_session/1`'s output, since
  `TradingCore.MarketHours.Session` is a shared struct other apps also
  build from their own data and this field only means something to the
  EOD-close worker.

  `market` is `TradingCore.MarketHours.Session.market` — the stable
  identifier `TradingCore.MarketHours.holiday?/2` keys its static holiday
  calendar off. Defaults to `"US_EQUITIES"`, the only market this app has
  any target pool members trading today.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @iso_weekdays 1..7

  schema "exchange_trading_hours" do
    field :name, :string
    field :timezone, :string
    field :start_time, :time
    field :end_time, :time
    field :enabled, :boolean, default: true
    field :days_of_week, {:array, :integer}, default: [1, 2, 3, 4, 5]
    field :close_before_minutes, :integer, default: 11
    field :market, :string, default: "US_EQUITIES"

    timestamps(type: :utc_datetime)
  end

  def changeset(exchange_trading_hours, attrs) do
    exchange_trading_hours
    |> cast(attrs, [
      :name,
      :timezone,
      :start_time,
      :end_time,
      :enabled,
      :days_of_week,
      :close_before_minutes,
      :market
    ])
    |> validate_required([
      :name,
      :timezone,
      :start_time,
      :end_time,
      :days_of_week,
      :close_before_minutes,
      :market
    ])
    |> validate_timezone()
    |> validate_days_of_week()
    |> validate_number(:close_before_minutes, greater_than_or_equal_to: 0)
    |> unique_constraint(:name)
  end

  @doc """
  Converts a row of this schema to a `TradingCore.MarketHours.Session`
  for time-math. `extra_holidays` is always `[]` — see this module's own
  moduledoc on why there's no manual-holiday equivalent yet.
  """
  @spec to_session(%__MODULE__{}) :: TradingCore.MarketHours.Session.t()
  def to_session(%__MODULE__{} = row) do
    %TradingCore.MarketHours.Session{
      name: row.name,
      timezone: row.timezone,
      start_time: row.start_time,
      end_time: row.end_time,
      enabled: row.enabled,
      days_of_week: row.days_of_week,
      market: row.market,
      extra_holidays: []
    }
  end

  defp validate_timezone(changeset) do
    case get_change(changeset, :timezone) do
      nil ->
        changeset

      tz ->
        if Tzdata.zone_exists?(tz) do
          changeset
        else
          add_error(changeset, :timezone, "is not a recognized IANA time zone")
        end
    end
  end

  defp validate_days_of_week(changeset) do
    validate_change(changeset, :days_of_week, fn :days_of_week, days ->
      cond do
        days == [] ->
          [days_of_week: "must include at least one day"]

        not Enum.all?(days, &(&1 in @iso_weekdays)) ->
          [days_of_week: "must contain only ISO weekday integers (1=Monday..7=Sunday)"]

        true ->
          []
      end
    end)
  end
end
