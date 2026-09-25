defmodule TradingOptionsSimWeb.StrategySearch do
  @moduledoc """
  The search box on the strategy versions, active strategies, runs and
  candidates pages. A row matches when the query appears in its strategy
  name (case-insensitive), or when the query looks like a UUID fragment
  and appears in one of the row's ids. Ids are the strategy version,
  strategy and, on the runs page, run.

  Id matching is a substring match that needs at least 6 characters of
  hex or dashes, so a short word like "dead" or "face" doesn't match
  random ids. It still matches a name containing it. Our ids are UUIDv7,
  whose first 8 hex characters are a millisecond timestamp, so rows
  created together share that prefix. Paste the full UUID, or its tail
  (the last 12 characters are random), to pick out one row. An empty
  query matches everything.

  Pure; each page passes a function returning `{name, ids}` for a row.
  """

  @uuid_fragment ~r/\A[0-9a-f-]{6,}\z/

  @doc "Keeps the items matching `query`. `fields` maps an item to `{name, [id]}`."
  @spec filter([item], String.t() | nil, (item -> {String.t() | nil, [String.t() | nil]})) ::
          [item]
        when item: term()
  def filter(items, query, fields) do
    case normalize(query) do
      "" -> items
      q -> Enum.filter(items, &matches_normalized?(q, fields.(&1)))
    end
  end

  @doc "Whether `name` or one of `ids` matches `query`; see the moduledoc."
  @spec matches?(String.t() | nil, String.t() | nil, [String.t() | nil]) :: boolean()
  def matches?(query, name, ids) do
    case normalize(query) do
      "" -> true
      q -> matches_normalized?(q, {name, ids})
    end
  end

  defp matches_normalized?(q, {name, ids}) do
    contains?(name, q) or (Regex.match?(@uuid_fragment, q) and Enum.any?(ids, &contains?(&1, q)))
  end

  defp contains?(nil, _q), do: false
  defp contains?(value, q), do: value |> to_string() |> String.downcase() |> String.contains?(q)

  defp normalize(nil), do: ""
  defp normalize(query), do: query |> to_string() |> String.trim() |> String.downcase()
end
