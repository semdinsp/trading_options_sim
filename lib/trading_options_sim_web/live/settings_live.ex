defmodule TradingOptionsSimWeb.SettingsLive do
  @moduledoc """
  Operator settings page — token management for `/api/v1` and this
  app's MCP server (one token type backs both, per
  `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §4a/§4b). Not yet styled per this
  app's own `DESIGN.md` "Dark Pool" theme — that theme was never
  actually implemented in this app's `Layouts` module (still the plain
  generator default); functional first, restyle as a separate pass.
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
     |> assign(:rolled_token_ref, nil)}
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
      <h1 class="text-2xl font-bold mb-6">Settings</h1>

      <section class="mb-8">
        <h2 class="text-lg font-semibold mb-2">API / MCP Tokens</h2>
        <p class="text-sm opacity-75 mb-4">
          One token type backs both <code>/api/v1</code>
          and this app's MCP server. A newly created token's raw value is shown once, below, then hidden.
        </p>

        <div :if={@rolled_token} id="rolled-token-panel" class="alert alert-warning mb-4">
          <div>
            <div class="font-semibold">New token — copy it now, it won't be shown again:</div>
            <code id="rolled-token-value" class="break-all">{@rolled_token}</code>
          </div>
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
              <label class="label">Label</label>
              <input
                type="text"
                name="api_token[label]"
                value={Phoenix.HTML.Form.input_value(@token_form, :label)}
                class="input input-bordered"
                placeholder="e.g. claude-code-daily-loop"
              />
            </div>

            <div>
              <label class="label">Scopes</label>
              <div class="flex flex-wrap gap-2">
                <label :for={scope <- @available_scopes} class="label cursor-pointer gap-1">
                  <input
                    type="checkbox"
                    name="api_token[scopes][]"
                    value={scope}
                    class="checkbox checkbox-sm"
                  />
                  <span class="text-xs">{scope}</span>
                </label>
              </div>
            </div>

            <button type="submit" class="btn btn-primary">Create token</button>
          </div>
        </.form>

        <table class="table">
          <thead>
            <tr>
              <th>Label</th>
              <th>Scopes</th>
              <th>Status</th>
              <th>Last used</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={token <- @tokens}>
              <td>{token.label}</td>
              <td class="text-xs">{Enum.join(token.scopes, ", ")}</td>
              <td>{token_status(token)}</td>
              <td>{token.last_used_at || "never"}</td>
              <td>
                <button
                  :if={is_nil(token.revoked_at)}
                  type="button"
                  phx-click="revoke_token"
                  phx-value-id={token.id}
                  data-confirm="Revoke this token? This cannot be undone."
                  class="btn btn-sm btn-error"
                >
                  Revoke
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </Layouts.app>
    """
  end
end
