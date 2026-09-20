defmodule TradingOptionsSim.Sim.Caveat do
  @moduledoc """
  Parses the structured caveat block out of a `StrategyVersion`'s `notes`
  prose, so a consumer can *ask* "does anything I reference have an open
  caveat?" instead of fetching every note and pattern-matching English.

  Ported from `TradingSignal.Signals.Caveat` (branch
  `claude/queryable-caveats`) — same format, same kinds, same `open?/1`
  rule — so a cross-app consumer sees one shape. Only the domain of what
  gets caveated differs: strategy versions here, signal definitions
  there.

  ## Why this exists rather than a separate column

  `notes` was always served — it is in `Api.Serializer.strategy_version/1`,
  so the REST catalog and the MCP tools carry it in full. Discoverability
  was never the problem. The problem is that prose is not queryable: with
  31 versions there is no way to ask which carry a caveat without
  fetching every note and reading English, so nobody asks.

  A separate structured column would be the obvious fix and the wrong
  one: two places to write the same fact, and nothing keeping them
  honest. Within a month the column says `severity: :warning` while the
  prose explains a defect fixed a fortnight ago. So the prose *is* the
  source of truth and this module reads it.

  ## Why it matters here specifically

  This app's notes are short (166 chars average, 195 max at the time of
  writing) so nothing is *buried* the way a 2000-character signal note
  buries things. The risk here is the opposite one: facts that were
  never written down at all. Several run populations in this app are not
  comparable with each other — different pricing backends, different
  implied-vol assumptions, contracts that did not resolve — and every one
  of those was known only from git history until it was written into a
  note a consumer can query.

  ## The format

  A caveated note opens with a caveat block, before anything else:

      CAVEATS FIRST — one live, one permanent.
      (1) HISTORY BEFORE 2026-09-18 IS NOT COMPARABLE: <body>
      (2) DO NOT TRUST THE NAME: <body>

      Origin: ...

  Each numbered entry is `(N) LABEL: body`, where `LABEL` is uppercase and
  becomes the machine-readable handle. The block ends at the first blank
  line. A note with no `CAVEATS` opener parses to `[]`.

  Caveats MUST come first. A note that opens with its thesis and corrects
  that reading three sentences later is exactly the failure this is meant
  to prevent: the opening sentence is what a consuming session believes.

  ## Kinds

  `LABEL` is classified into a `t:kind/0` so a consumer can act
  differently per class — the distinction that matters is whether a
  machine can act on it at all:

    * `:data` — the values are currently wrong or unusable
      (`DO NOT ACT ON THE NUMBER`). A consumer can act automatically:
      suppress, warn, refuse to gate on it.
    * `:history` — past values are not comparable with present ones
      (`HISTORY BEFORE ... IS NOT COMPARABLE`). Actionable by anything
      choosing a backtest or evaluation range. This is the common kind
      in this app.
    * `:semantic` — it measures something other than its name suggests
      (`DO NOT TRUST THE NAME`). Irreducibly a human-read thing, but it
      can at least be *surfaced* to whoever authors a condition.
    * `:applicability` — valid only in some contexts (`EXIT-ONLY`,
      `ENTRY-ONLY`). Contributed by `trading_system`. Machine-actionable
      in the strongest sense: a generator that can query this refuses to
      build a dead rule instead of discovering it in the PnL.
    * `:other` — anything else; advisory.

  `:data`, `:history` and `:applicability` are `open?/1`. `:semantic` is
  not, and the line is *permanent-and-unactionable* rather than merely
  permanent: a `:semantic` caveat never clears and only a human can act
  on it, so treating it as open would flag that row forever until the
  flag stopped being read. `:applicability` also never clears, but it
  constrains every individual use and a machine can act on it each time,
  so it stays open.
  """

  @enforce_keys [:kind, :label, :body]
  defstruct [:kind, :label, :body]

  @type kind :: :data | :history | :semantic | :applicability | :other

  @type t :: %__MODULE__{kind: kind(), label: String.t(), body: String.t()}

  @caveat_opener "CAVEATS"

  # :semantic is excluded deliberately — see the moduledoc's Kinds
  # section on why the axis is actionability rather than permanence.
  @open_kinds [:data, :history, :applicability]

  @doc """
  Every caveat in `notes`, in document order. `[]` for a note with no
  caveat block, for `nil`, and for a blank string.
  """
  @spec parse(String.t() | nil) :: [t()]
  def parse(nil), do: []

  def parse(notes) when is_binary(notes) do
    if String.starts_with?(notes, @caveat_opener) do
      notes
      |> caveat_block()
      |> entries()
    else
      []
    end
  end

  @doc """
  True when `notes` carries at least one caveat a consumer should act on
  — `:data`, `:history` or `:applicability`. A `:semantic` caveat alone
  is not "open".
  """
  @spec open?(String.t() | nil) :: boolean()
  def open?(notes), do: notes |> parse() |> Enum.any?(&(&1.kind in @open_kinds))

  @doc """
  Every caveat of `kind` in `notes` — for a consumer acting on one class,
  e.g. constraining an evaluation range on `:history` while only
  surfacing `:semantic` ones to a human author.
  """
  @spec of_kind(String.t() | nil, kind()) :: [t()]
  def of_kind(notes, kind), do: notes |> parse() |> Enum.filter(&(&1.kind == kind))

  @doc """
  One-line summary for a catalog row — `nil` when there are no caveats,
  so a caller can `case` on presence without counting.
  """
  @spec summary(String.t() | nil) :: String.t() | nil
  def summary(notes) do
    case parse(notes) do
      [] -> nil
      caveats -> Enum.map_join(caveats, "; ", & &1.label)
    end
  end

  @doc """
  Serializable shape for an API row — the struct as a plain map with
  string keys, matching how `Api.Serializer` renders everything else.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = caveat) do
    %{"kind" => Atom.to_string(caveat.kind), "label" => caveat.label, "body" => caveat.body}
  end

  # The block runs from the opener to the first blank line — i.e. the
  # start of the ordinary prose.
  defp caveat_block(notes) do
    notes
    |> String.split(~r/\n[ \t]*\n/, parts: 2)
    |> hd()
  end

  defp entries(block) do
    Regex.scan(~r/^\((\d+)\)\s*([^:\n]+):\s*(.+?)(?=\n\(\d+\)|\z)/ms, block)
    |> Enum.map(fn [_full, _n, label, body] ->
      label = String.trim(label)

      %__MODULE__{
        kind: classify(label),
        label: label,
        body: body |> String.trim() |> String.replace(~r/\s+/, " ")
      }
    end)
  end

  defp classify(label) do
    upcased = String.upcase(label)

    cond do
      String.contains?(upcased, "HISTORY") -> :history
      String.contains?(upcased, "EXIT-ONLY") -> :applicability
      String.contains?(upcased, "ENTRY-ONLY") -> :applicability
      String.contains?(upcased, "DO NOT ACT") -> :data
      String.contains?(upcased, "PREFER") -> :data
      String.contains?(upcased, "DO NOT TRUST THE NAME") -> :semantic
      String.contains?(upcased, "NAME") -> :semantic
      true -> :other
    end
  end
end
