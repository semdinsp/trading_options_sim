defmodule TradingOptionsSimWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use TradingOptionsSimWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <.trading_navbar />

    <main class="px-4 py-8 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-6xl">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Renders this app's only navbar (§ "Layout patterns", DESIGN.md).
  """
  def trading_navbar(assigns) do
    ~H"""
    <header class="navbar bg-base-300 border-b border-primary/20 px-4 sm:px-6 lg:px-8 min-h-14 h-14">
      <div class="navbar-start">
        <a href="/" class="flex items-center gap-2 px-2">
          <span class="w-2 h-2 bg-primary shrink-0"></span>
          <span class="text-lg font-bold uppercase tracking-[0.08em] text-base-content">
            Trading<span class="text-primary">://</span>OptionsSim
          </span>
        </a>
      </div>

      <div class="navbar-end">
        <ul class="menu menu-horizontal px-1 gap-1 font-data text-xs uppercase tracking-wider">
          <li>
            <a
              href="/active_strategies"
              class="rounded-none border border-transparent hover:border-primary/40 hover:bg-primary/10 hover:text-primary"
            >
              <.icon name="hero-signal" class="h-4 w-4 mr-1" /> Active
            </a>
          </li>
          <li>
            <a
              href="/runs"
              class="rounded-none border border-transparent hover:border-primary/40 hover:bg-primary/10 hover:text-primary"
            >
              <.icon name="hero-list-bullet" class="h-4 w-4 mr-1" /> Runs
            </a>
          </li>
          <li>
            <a
              href="/strategy_versions"
              class="rounded-none border border-transparent hover:border-primary/40 hover:bg-primary/10 hover:text-primary"
            >
              <.icon name="hero-squares-2x2" class="h-4 w-4 mr-1" /> Versions
            </a>
          </li>
          <li>
            <a
              href="/candidates"
              class="rounded-none border border-transparent hover:border-primary/40 hover:bg-primary/10 hover:text-primary"
            >
              <.icon name="hero-trophy" class="h-4 w-4 mr-1" /> Candidates
            </a>
          </li>
          <li>
            <a
              href="/system-performance"
              class="rounded-none border border-transparent hover:border-primary/40 hover:bg-primary/10 hover:text-primary"
            >
              <.icon name="hero-server" class="h-4 w-4 mr-1" /> System
            </a>
          </li>
          <li>
            <a
              href="/settings"
              title="Settings"
              aria-label="Settings"
              class="rounded-none border border-transparent hover:border-primary/40 hover:bg-primary/10 hover:text-primary"
            >
              <.icon name="hero-cog-6-tooth" class="h-4 w-4" />
            </a>
          </li>
        </ul>
      </div>
    </header>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
