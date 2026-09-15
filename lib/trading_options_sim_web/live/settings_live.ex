defmodule TradingOptionsSimWeb.SettingsLive do
  @moduledoc """
  Operator settings page — token management for `/api/v1` and this
  app's MCP server (one token type backs both, per
  `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §4a/§4b), tag pool management
  (§3a) — creating a tag here is optional (both
  `add_tag_to_strategy_version_by_name/2` and `add_tag_to_run_by_name/2`
  get-or-create on the fly), but deleting one is only ever safe/visible
  as a deliberate, explicit action, so it lives here rather than being
  reachable from a tag chip on `StrategyVersionsLive`/`RunsLive` — a
  Database Backup panel (a manual "Back up database now" button
  wrapping `TradingOptionsSim.DbBackup.dump/2`, a config-swappable
  adapter over the sibling `trading_core` library's
  `TradingCore.DbBackup.dump/3` — ported from `trading_system`'s
  identical panel) — and a dev-only link into Phoenix.LiveDashboard
  (`/dev/dashboard`, already mounted in the router, just never linked
  from anywhere), same `dev_routes`-gated pattern `trading_system`'s
  own Settings page uses.
  """

  use TradingOptionsSimWeb, :live_view

  require Logger

  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.Sim.ApiToken

  # How long a freshly-rolled raw token stays visible before this
  # LiveView hides it again — same "shown once, then hidden" posture
  # trading_system's own SettingsLive uses for its rolled tokens.
  @rolled_token_display_ms :timer.seconds(60)

  @backup_reminder_after_days 30

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:tokens, Sim.list_api_tokens())
     |> assign(:available_scopes, ApiToken.scopes())
     |> assign(:token_form, fresh_token_form())
     |> assign(:rolled_token, nil)
     |> assign(:rolled_token_ref, nil)
     |> assign(:tags, Sim.list_tags())
     |> assign(:new_tag_name, "")
     |> assign(:backup_running?, false)
     |> assign(:backup_result, nil)
     |> assign(:latest_backup, latest_backup(backup_dir()))
     |> assign(:backup_reminder_dismissed?, false)
     |> assign(:dev_routes?, Application.get_env(:trading_options_sim, :dev_routes, false))}
  end

  @impl true
  def handle_event("validate_token", %{"api_token" => params}, socket) do
    {:noreply, assign(socket, :token_form, to_form(params, as: "api_token"))}
  end

  def handle_event("create_token", %{"api_token" => params}, socket) do
    label = params |> Map.get("label", "") |> String.trim()
    scopes = scopes_from_params(params)

    cond do
      label == "" ->
        {:noreply,
         put_flash(socket, :error, "Give the token a label so you can tell it apart later.")}

      scopes == [] ->
        {:noreply, put_flash(socket, :error, "Pick at least one scope.")}

      true ->
        case Sim.create_api_token(label, scopes) do
          {:ok, {raw, _token}} ->
            ref = make_ref()
            Process.send_after(self(), {:hide_rolled_token, ref}, @rolled_token_display_ms)

            {:noreply,
             socket
             |> put_flash(:info, "New token created")
             |> assign(:tokens, Sim.list_api_tokens())
             |> assign(:token_form, fresh_token_form())
             |> assign(:rolled_token, raw)
             |> assign(:rolled_token_ref, ref)}

          {:error, changeset} ->
            {:noreply, assign(socket, :token_form, to_form(changeset, as: "api_token"))}
        end
    end
  end

  def handle_event("revoke_token", %{"id" => id}, socket) do
    token = Enum.find(socket.assigns.tokens, &(&1.id == id))

    if token do
      {:ok, _} = Sim.revoke_api_token(token)
    end

    {:noreply,
     socket
     |> put_flash(:info, "Token revoked")
     |> assign(:tokens, Sim.list_api_tokens())}
  end

  def handle_event("create_tag", %{"tag_name" => tag_name}, socket) do
    trimmed = String.trim(tag_name)

    if trimmed == "" do
      {:noreply, socket}
    else
      {:ok, _tag} = Sim.get_or_create_tag(trimmed)

      {:noreply,
       socket
       |> assign(:tags, Sim.list_tags())
       |> assign(:new_tag_name, "")}
    end
  end

  def handle_event("delete_tag", %{"id" => id}, socket) do
    tag = Enum.find(socket.assigns.tags, &(&1.id == id))

    if tag do
      {:ok, _} = Sim.delete_tag(tag)
    end

    {:noreply,
     socket
     |> put_flash(:info, "Tag deleted")
     |> assign(:tags, Sim.list_tags())}
  end

  # start_async/3, not a bare Task.async — a real pg_dump can take
  # anywhere from seconds to several minutes
  # (TradingCore.DbBackup.dump/3's own default 300_000ms timeout) and
  # must never block this LiveView process or the page it's rendering.
  def handle_event("run_backup", _params, socket) do
    dir = backup_dir()

    {:noreply,
     socket
     |> assign(:backup_running?, true)
     |> assign(:backup_result, nil)
     |> start_async(:db_backup, fn ->
       TradingOptionsSim.DbBackup.dump(TradingOptionsSim.Repo.config(), dir)
     end)}
  end

  def handle_event("dismiss_backup_reminder", _params, socket) do
    {:noreply, assign(socket, :backup_reminder_dismissed?, true)}
  end

  @impl true
  def handle_async(:db_backup, {:ok, {:ok, _path} = result}, socket) do
    {:noreply,
     socket
     |> assign(:backup_running?, false)
     |> assign(:backup_result, result)
     |> assign(:latest_backup, latest_backup(backup_dir()))
     |> assign(:backup_reminder_dismissed?, false)}
  end

  def handle_async(:db_backup, {:ok, {:error, _reason} = result}, socket) do
    {:noreply,
     socket
     |> assign(:backup_running?, false)
     |> assign(:backup_result, result)}
  end

  def handle_async(:db_backup, {:exit, reason}, socket) do
    Logger.error("SettingsLive: TradingOptionsSim.DbBackup.dump/2 crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:backup_running?, false)
     |> assign(:backup_result, {:error, {:crashed, reason}})}
  end

  @impl true
  def handle_info({:hide_rolled_token, ref}, socket) do
    if socket.assigns.rolled_token_ref == ref do
      {:noreply, assign(socket, rolled_token: nil, rolled_token_ref: nil)}
    else
      {:noreply, socket}
    end
  end

  defp fresh_token_form do
    to_form(%{"label" => "", "scopes" => []}, as: "api_token")
  end

  defp scopes_from_params(params) do
    params
    |> Map.get("scopes", [])
    |> List.wrap()
    |> Enum.reject(&(&1 == ""))
  end

  defp token_status(%{revoked_at: revoked_at}) when not is_nil(revoked_at), do: "revoked"
  defp token_status(_token), do: "active"

  # Overridable via TRADING_OPTIONS_SIM_BACKUP_DIR (config/runtime.exs)
  # — no existing app-wide "writable data directory" convention to
  # reuse, so this picks the same priv_dir-relative default a fresh
  # checkout with no env override would already have write access to.
  # Same convention trading_system's identical panel uses.
  defp backup_dir do
    Application.get_env(
      :trading_options_sim,
      :backup_dir,
      Path.join(:code.priv_dir(:trading_options_sim), "backups")
    )
  end

  # Newest .pgdump file for THIS app's own database name — a shared
  # backup_dir could plausibly hold dumps from other apps/environments,
  # and DbBackup.dump/3's own "<database>-<timestamp>.pgdump" naming
  # makes filtering on that cheap and unambiguous. Filename sorts
  # chronologically by construction, so lexicographic Enum.max/1 on the
  # matching names is enough — no need to stat every file's mtime just
  # to find the newest.
  defp latest_backup(dir) do
    database = Keyword.fetch!(TradingOptionsSim.Repo.config(), :database)
    prefix = database <> "-"

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&(String.starts_with?(&1, prefix) and String.ends_with?(&1, ".pgdump")))
        |> Enum.max(&>=/2, fn -> nil end)
        |> case do
          nil -> nil
          filename -> stat_backup(Path.join(dir, filename))
        end

      {:error, _reason} ->
        nil
    end
  end

  defp stat_backup(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{size: size, mtime: mtime_posix}} ->
        %{path: path, size: size, mtime: DateTime.from_unix!(mtime_posix)}

      {:error, _reason} ->
        nil
    end
  end

  defp backup_stale?(%{mtime: mtime}, dismissed?) do
    not dismissed? and
      DateTime.diff(DateTime.utc_now(), mtime, :day) >= @backup_reminder_after_days
  end

  defp backup_age_label(%{mtime: mtime}) do
    days = DateTime.diff(DateTime.utc_now(), mtime, :day)
    "#{days} day#{if days == 1, do: "", else: "s"} ago"
  end

  defp backup_result_label({:ok, path}) do
    "Backup complete: #{Path.basename(path)}"
  end

  defp backup_result_label({:error, {:pg_dump_not_found, path}}) do
    "Backup failed: pg_dump not found (looked for #{path}). Is it installed and on PATH?"
  end

  defp backup_result_label({:error, {:pg_dump_failed, exit_status, output}}) do
    "Backup failed: pg_dump exited #{exit_status}. #{String.slice(output, 0, 300)}"
  end

  defp backup_result_label({:error, {:pg_dump_timeout, timeout}}) do
    "Backup failed: pg_dump did not finish within #{div(timeout, 1000)}s."
  end

  defp backup_result_label({:error, {:crashed, reason}}) do
    "Backup failed unexpectedly: #{inspect(reason)}"
  end

  defp backup_result_label({:error, reason}) do
    "Backup failed: #{inspect(reason)}"
  end

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp format_bytes(bytes) when bytes >= 1_000_000_000 do
    "#{Float.round(bytes / 1_000_000_000, 2)} GB"
  end

  defp format_bytes(bytes) when bytes >= 1_000_000 do
    "#{Float.round(bytes / 1_000_000, 2)} MB"
  end

  defp format_bytes(bytes) when bytes >= 1_000 do
    "#{Float.round(bytes / 1_000, 1)} KB"
  end

  defp format_bytes(bytes), do: "#{bytes} B"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1 class="text-2xl font-bold uppercase tracking-wide mb-6">Settings</h1>

      <section class="mb-8">
        <h2 class="font-bold uppercase tracking-wide mb-2">API / MCP Tokens</h2>
        <p class="text-sm text-base-content/60 mb-4">
          One token type backs both <code class="font-data">/api/v1</code>
          and this app's MCP server. A newly created token's raw value is shown once, below, then hidden.
        </p>

        <div
          :if={@rolled_token}
          id="rolled-token-panel"
          class="border border-primary/40 bg-primary/10 p-4 mb-4"
        >
          <div class="font-bold uppercase tracking-wide text-xs mb-1">
            New token — copy it now, it won't be shown again:
          </div>
          <code id="rolled-token-value" class="font-data break-all">{@rolled_token}</code>
        </div>

        <.form
          for={@token_form}
          id="api-token-form"
          phx-change="validate_token"
          phx-submit="create_token"
          class="mb-6"
        >
          <div class="flex flex-wrap gap-4 items-end">
            <div>
              <label
                for="api-token-label-input"
                class="block text-xs uppercase tracking-wide text-base-content/60 mb-1"
              >
                Label
              </label>
              <input
                type="text"
                id="api-token-label-input"
                name="api_token[label]"
                value={Phoenix.HTML.Form.input_value(@token_form, :label)}
                class="input input-bordered font-data text-sm"
                placeholder="e.g. claude-code-daily-loop"
              />
            </div>

            <div>
              <span class="block text-xs uppercase tracking-wide text-base-content/60 mb-1">
                Scopes
              </span>
              <div class="flex flex-wrap gap-2">
                <label :for={scope <- @available_scopes} class="label cursor-pointer gap-1">
                  <input
                    type="checkbox"
                    name="api_token[scopes][]"
                    value={scope}
                    class="checkbox checkbox-sm"
                  />
                  <span class="font-data text-xs">{scope}</span>
                </label>
              </div>
            </div>

            <button type="submit" class="btn btn-primary rounded-none">
              <.icon name="hero-plus" class="h-4 w-4" /> Create token
            </button>
          </div>
        </.form>

        <table class="table font-data text-xs">
          <thead class="bg-base-300 uppercase tracking-wide text-[11px]">
            <tr>
              <th>Label</th>
              <th>Scopes</th>
              <th>Status</th>
              <th>Last used</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={token <- @tokens} class="border-t border-base-300">
              <td>{token.label}</td>
              <td>{Enum.join(token.scopes, ", ")}</td>
              <td>{token_status(token)}</td>
              <td>{(token.last_used_at && format_datetime(token.last_used_at)) || "never"}</td>
              <td>
                <button
                  :if={is_nil(token.revoked_at)}
                  type="button"
                  phx-click="revoke_token"
                  phx-value-id={token.id}
                  data-confirm="Revoke this token? This cannot be undone."
                  class="px-1.5 py-0.5 border border-error/40 text-error bg-error/10 text-[11px] uppercase tracking-wide hover:bg-error/20"
                >
                  Revoke
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </section>

      <section class="mb-8">
        <h2 class="font-bold uppercase tracking-wide mb-2">Tags</h2>
        <p class="text-sm text-base-content/60 mb-4">
          Shared tag pool applied to strategy versions and runs. Creating a tag here is
          optional — tagging a version or run elsewhere creates it on the fly — but deleting one
          is a deliberate action, so it only happens here.
        </p>

        <.form for={%{}} as={:tag} phx-submit="create_tag" class="mb-4 flex items-end gap-2">
          <div>
            <label
              for="new-tag-name-input"
              class="block text-xs uppercase tracking-wide text-base-content/60 mb-1"
            >
              New tag
            </label>
            <input
              type="text"
              id="new-tag-name-input"
              name="tag_name"
              value={@new_tag_name}
              class="input input-bordered font-data text-sm"
              placeholder="e.g. needs-review"
            />
          </div>
          <button type="submit" class="btn btn-primary rounded-none">
            <.icon name="hero-plus" class="h-4 w-4" /> Add tag
          </button>
        </.form>

        <div :if={@tags == []} class="text-sm text-base-content/40 font-data">No tags yet</div>

        <div :if={@tags != []} class="flex flex-wrap gap-2">
          <span
            :for={tag <- @tags}
            class="inline-flex items-center gap-2 px-2 py-1 border border-secondary/40 text-secondary bg-secondary/10 text-xs uppercase tracking-wide font-data"
          >
            {tag.name}
            <button
              type="button"
              phx-click="delete_tag"
              phx-value-id={tag.id}
              data-confirm="Delete this tag? It will be removed from every strategy version and run it's applied to. This cannot be undone."
              class="hover:text-error"
            >
              <.icon name="hero-x-mark" class="h-3.5 w-3.5" />
            </button>
          </span>
        </div>
      </section>

      <section class="mb-8">
        <h2 class="font-bold uppercase tracking-wide mb-2">Strategy Lifecycle</h2>
        <p class="text-sm text-base-content/60 mb-4">
          Retired versions are hidden from the main Strategy Versions list by default. A
          retired version can be unretired back to discovery from the Retired filter.
        </p>

        <.link
          navigate={~p"/strategy_versions?stage=retired"}
          class="btn btn-primary rounded-none"
        >
          <.icon name="hero-archive-box" class="h-4 w-4" /> Show Retired Versions
        </.link>
      </section>

      <section class="mb-8">
        <h2 class="font-bold uppercase tracking-wide mb-2">Database Backup</h2>

        <div
          :if={@latest_backup && backup_stale?(@latest_backup, @backup_reminder_dismissed?)}
          id="backup-reminder-banner"
          class="border border-warning/40 bg-warning/10 text-warning px-3 py-2 mb-3 flex items-center justify-between gap-2 text-sm"
        >
          <span>
            It's been over a month since your last database backup ({backup_age_label(@latest_backup)}) — back up now.
          </span>
          <button
            type="button"
            phx-click="dismiss_backup_reminder"
            class="shrink-0 hover:text-error"
            title="Dismiss for this session"
            aria-label="Dismiss backup reminder for this session"
          >
            <.icon name="hero-x-mark" class="h-4 w-4" />
          </button>
        </div>
        <div
          :if={!@latest_backup}
          id="backup-reminder-banner-no-backup"
          class="border border-warning/40 bg-warning/10 text-warning px-3 py-2 mb-3 text-sm"
        >
          No backup found yet — back up now to establish a baseline.
        </div>

        <p class="text-sm text-base-content/60 mb-4">
          Runs <span class="font-data">pg_dump</span>
          (custom format, restorable with <span class="font-data">pg_restore</span>)
          against this app's own database and writes the result to <span class="font-data">{backup_dir()}</span>. Can take a while on a large database —
          runs in the background, this page stays usable while it's in progress.
        </p>

        <div class="space-y-2">
          <div :if={@latest_backup} class="text-xs font-data space-y-1 text-base-content/70">
            <div>Last backup: {format_datetime(@latest_backup.mtime)} UTC</div>
            <div>Size: {format_bytes(@latest_backup.size)}</div>
            <div>File: {Path.basename(@latest_backup.path)}</div>
          </div>

          <div
            :if={@backup_result}
            class={[
              "border px-3 py-2 text-sm",
              if(match?({:ok, _}, @backup_result),
                do: "border-success/40 bg-success/10 text-success",
                else: "border-error/40 bg-error/10 text-error"
              )
            ]}
          >
            {backup_result_label(@backup_result)}
          </div>

          <button
            type="button"
            phx-click="run_backup"
            disabled={@backup_running?}
            class="btn btn-primary rounded-none"
          >
            <.icon
              name={if @backup_running?, do: "hero-arrow-path", else: "hero-circle-stack"}
              class={["h-4 w-4", @backup_running? && "motion-safe:animate-spin"]}
            />
            {if @backup_running?, do: "Backing up…", else: "Back up database now"}
          </button>
        </div>
      </section>

      <section :if={@dev_routes?}>
        <h2 class="font-bold uppercase tracking-wide mb-2">LiveDashboard</h2>
        <p class="text-sm text-base-content/60 mb-2">
          Development tool — real-time BEAM/Ecto/Phoenix metrics, process inspector, and request
          logging. Not present in a production build (gated on
          <span class="font-data">dev_routes</span>
          at compile time, same as the route itself).
        </p>
        <a href="/dev/dashboard" target="_blank" class="btn btn-primary rounded-none">
          <.icon name="hero-arrow-top-right-on-square" class="h-4 w-4" /> Open LiveDashboard
        </a>
      </section>
    </Layouts.app>
    """
  end
end
