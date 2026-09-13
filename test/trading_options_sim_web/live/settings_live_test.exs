defmodule TradingOptionsSimWeb.SettingsLiveTest do
  use TradingOptionsSimWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias TradingOptionsSim.Sim

  test "renders the tokens section", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings")
    assert html =~ "API / MCP Tokens"
  end

  test "lists existing tokens", %{conn: conn} do
    {:ok, {_raw, _token}} = Sim.create_api_token("existing-token", ["strategies:read"])

    {:ok, _view, html} = live(conn, ~p"/settings")
    assert html =~ "existing-token"
  end

  test "creating a token shows the raw value once and adds it to the list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    html =
      view
      |> form("form", %{
        "api_token" => %{"label" => "new-token", "scopes" => ["strategies:read"]}
      })
      |> render_submit()

    assert html =~ "new-token"
    assert html =~ "New token — copy it now"

    assert Enum.any?(Sim.list_api_tokens(), &(&1.label == "new-token"))
  end

  test "rejects a blank label", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    html =
      view
      |> form("form", %{"api_token" => %{"label" => "", "scopes" => ["strategies:read"]}})
      |> render_submit()

    assert html =~ "Give the token a label"
  end

  test "rejects no scopes selected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    html =
      view
      |> form("form", %{"api_token" => %{"label" => "no-scopes", "scopes" => []}})
      |> render_submit()

    assert html =~ "Pick at least one scope"
  end

  test "revoking a token updates its status", %{conn: conn} do
    {:ok, {_raw, token}} = Sim.create_api_token("revoke-me", ["strategies:read"])

    {:ok, view, _html} = live(conn, ~p"/settings")

    html =
      view
      |> element("button[phx-value-id='#{token.id}']")
      |> render_click()

    assert html =~ "revoked"
  end
end
