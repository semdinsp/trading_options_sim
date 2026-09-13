defmodule TradingOptionsSimWeb.SettingsLive do
  @moduledoc """
  Operator settings page — token management for `/api/v1` and this
  app's MCP server (one token type backs both, per
  `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §4a/§4b), plus tag pool management
  (§3a) — creating a tag here is optional (both
  `add_tag_to_strategy_version_by_name/2` and `add_tag_to_run_by_name/2`
  get-or-create on the fly), but deleting one is only ever safe/visible
  as a deliberate, explicit action, so it lives here rather than being
  reachable from a tag chip on `StrategyVersionsLive`/`RunsLive`.
  """

  use TradingOptionsSimWeb, :live_view

  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.Sim.ApiToken

  # How long a freshly-rolled raw token stays visible before this
  # LiveView hides it again — same "shown once, then hidden" posture
  # trading_system's own SettingsLive uses for its rolled tokens.
  @rolled_token_display_ms :timer.seconds(60)

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
     |> assign(:new_tag_name, "")}
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
              <label class="block text-xs uppercase tracking-wide text-base-content/60 mb-1">
                Label
              </label>
              <input
                type="text"
                name="api_token[label]"
                value={Phoenix.HTML.Form.input_value(@token_form, :label)}
                class="input input-bordered font-data text-sm"
                placeholder="e.g. claude-code-daily-loop"
              />
            </div>

            <div>
              <label class="block text-xs uppercase tracking-wide text-base-content/60 mb-1">
                Scopes
              </label>
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

            <button type="submit" class="btn btn-primary rounded-none">Create token</button>
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
              <td>{token.last_used_at || "never"}</td>
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

      <section>
        <h2 class="font-bold uppercase tracking-wide mb-2">Tags</h2>
        <p class="text-sm text-base-content/60 mb-4">
          Shared tag pool applied to strategy versions and runs. Creating a tag here is
          optional — tagging a version or run elsewhere creates it on the fly — but deleting one
          is a deliberate action, so it only happens here.
        </p>

        <.form for={%{}} as={:tag} phx-submit="create_tag" class="mb-4 flex items-end gap-2">
          <div>
            <label class="block text-xs uppercase tracking-wide text-base-content/60 mb-1">
              New tag
            </label>
            <input
              type="text"
              name="tag_name"
              value={@new_tag_name}
              class="input input-bordered font-data text-sm"
              placeholder="e.g. needs-review"
            />
          </div>
          <button type="submit" class="btn btn-primary rounded-none">Add tag</button>
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
    </Layouts.app>
    """
  end
end
