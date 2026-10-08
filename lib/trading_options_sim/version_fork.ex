defmodule TradingOptionsSim.VersionFork do
  @moduledoc """
  Forks a strategy version into a new Strategy, faithfully: the one path
  behind the `fork_version` MCP tool and `POST /api/v1/versions/:id/fork`.
  Modelled on trading_system's `fork_version`, but a fork here is a new
  Strategy at version 1 (as every existing "... [Var: ...]" fork was
  made), and everything not named in the request is copied from the
  source, including `params.risk_controls`, `overnight_hold` and
  `trading_hours_policy`, which `create_strategy_version` can't carry.

  Steps, all before anything is written:
    1. resolve the rule tree: the source's rules; `entry_gate` AND-ed onto
       the entry (`{"all": [source_entry, gate]}`, exit untouched); or
       `rules` replacing both. `entry_gate` and `rules` are exclusive.
    2. validate it with `StrategyVersion.rules_errors/1`, the same
       validator `create_strategy_version` runs.
    3. reject signal names this app can't supply (`unknown_signal_names/1`).
  Then `Sim.fork_strategy_version/2` writes it in one transaction, and
  `activate: true` starts monitors through `SimActivator.activate/1`, the
  same call as `activate_version`.
  """

  alias TradingCore.RuleEngine
  alias TradingOptionsSim.{ContractMonitor, SignalBus, Sim, SimActivator}
  alias TradingOptionsSim.Sim.StrategyVersion

  @type error ::
          :not_found
          | :name_required
          | :entry_gate_and_rules
          | {:invalid_rules, [String.t()]}
          | {:unknown_signals, [String.t()]}
          | {:signal_check_failed, [String.t()], term()}
          | Ecto.Changeset.t()

  @doc """
  `opts`: `:name` (required), `:entry_gate`, `:rules`, `:notes`, `:tags`,
  `:activate` (default false). Returns `{:ok, %{version: v, activation:
  a}}`, where `a` is `nil` when not activating, else
  `%{monitors: n, unsubscribed_symbols: [...]}` or `%{error: reason}`
  (the fork itself is kept if activation fails).
  """
  @spec fork(String.t(), map() | keyword()) :: {:ok, map()} | {:error, error()}
  def fork(source_id, opts) do
    opts = Map.new(opts)

    with {:ok, source} <- fetch_source(source_id),
         {:ok, name} <- fetch_name(opts),
         {:ok, rules} <- resolve_rules(source, opts),
         :ok <- validate_rules(rules),
         :ok <- check_signals(rules),
         {:ok, version} <-
           Sim.fork_strategy_version(source, %{
             name: name,
             rules: rules,
             notes: fork_notes(source, opts[:notes]),
             tags: List.wrap(opts[:tags])
           }) do
      {:ok, %{version: version, activation: maybe_activate(version, opts[:activate])}}
    end
  end

  @doc """
  Signal names in `rules` (entry and exit, `signal` and `value_signal`)
  that this app can't supply: not one of the monitor's own snapshot keys
  (`ContractMonitor.snapshot_keys/0`) and not a signal trading_signal
  knows (`SignalBus.resolve/1`, which checks without subscribing).
  Returns `{:ok, []}`, `{:ok, unknown}` or, when trading_signal can't be
  asked, `{:error, unchecked_names, reason}`.
  """
  @spec unknown_signal_names(map() | nil) ::
          {:ok, [String.t()]} | {:error, [String.t()], term()}
  def unknown_signal_names(rules) do
    rules = rules || %{}
    local = MapSet.new(ContractMonitor.snapshot_keys())

    remote =
      (RuleEngine.signal_names(rules["entry"]) ++ RuleEngine.signal_names(rules["exit"]))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(local, &1))

    results = Enum.map(remote, &{&1, SignalBus.resolve(&1)})

    case for({name, {:error, reason}} <- results, reason != :unknown_signal, do: {name, reason}) do
      [] ->
        {:ok, for({name, {:error, :unknown_signal}} <- results, do: name)}

      [{_, reason} | _] = failed ->
        {:error, Enum.map(failed, &elem(&1, 0)), reason}
    end
  end

  defp fetch_source(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id || ""),
         %StrategyVersion{deleted_at: nil} = v <-
           TradingOptionsSim.Repo.get(StrategyVersion, uuid) do
      {:ok, TradingOptionsSim.Repo.preload(v, :strategy)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp fetch_name(%{name: name}) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, :name_required}
      trimmed -> {:ok, trimmed}
    end
  end

  defp fetch_name(_opts), do: {:error, :name_required}

  defp resolve_rules(source, opts) do
    case {opts[:entry_gate], opts[:rules]} do
      {gate, rules} when not is_nil(gate) and not is_nil(rules) ->
        {:error, :entry_gate_and_rules}

      {nil, nil} ->
        {:ok, source.rules || %{}}

      {nil, rules} when is_map(rules) ->
        {:ok, rules}

      {gate, nil} when is_map(gate) ->
        source_rules = source.rules || %{}
        entry = Map.get(source_rules, "entry") || %{}
        {:ok, Map.put(source_rules, "entry", %{"all" => [entry, gate]})}

      _ ->
        {:error, {:invalid_rules, ["entry_gate and rules must be JSON objects"]}}
    end
  end

  defp validate_rules(rules) do
    case StrategyVersion.rules_errors(rules) do
      [] -> :ok
      errors -> {:error, {:invalid_rules, errors}}
    end
  end

  defp check_signals(rules) do
    case unknown_signal_names(rules) do
      {:ok, []} -> :ok
      {:ok, unknown} -> {:error, {:unknown_signals, unknown}}
      {:error, names, reason} -> {:error, {:signal_check_failed, names, reason}}
    end
  end

  defp fork_notes(source, notes) do
    stamp = "Forked from #{source.id} (#{source.strategy.name})."

    case notes && String.trim(notes) do
      blank when blank in [nil, ""] -> stamp
      text -> text <> "\n\n" <> stamp
    end
  end

  defp maybe_activate(_version, activate) when activate != true, do: nil

  defp maybe_activate(version, true) do
    case SimActivator.activate(version) do
      {:ok, pids, unsubscribed} -> %{monitors: length(pids), unsubscribed_symbols: unsubscribed}
      {:error, reason} -> %{error: reason}
    end
  end

  @doc "A one-line, human-readable message for an `error()` from `fork/2`."
  @spec describe_error(error()) :: String.t()
  def describe_error(:not_found), do: "no strategy version with that id"
  def describe_error(:name_required), do: "name is required"

  def describe_error(:entry_gate_and_rules),
    do: "pass entry_gate OR rules, not both (entry_gate is AND-ed onto the source entry)"

  def describe_error({:invalid_rules, errors}), do: "invalid rules: " <> Enum.join(errors, "; ")

  def describe_error({:unknown_signals, names}),
    do:
      "unknown signal names (not a monitor key or trading_signal signal): #{Enum.join(names, ", ")}"

  def describe_error({:signal_check_failed, names, reason}),
    do:
      "could not verify signals #{Enum.join(names, ", ")} with trading_signal (#{inspect(reason)})"

  def describe_error(%Ecto.Changeset{} = changeset),
    do: "failed to create the fork: #{inspect(changeset.errors)}"
end
