defmodule TradingOptionsSimWeb.SettingsLiveTest do
  use TradingOptionsSimWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias TradingOptionsSim.Sim

  test "renders the tokens section", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings")
    assert html =~ "API / MCP Tokens"
  end

  test "shows a link to the retired versions filter", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/settings")

    assert html =~ "Show Retired Versions"
    assert has_element?(view, "a[href='/strategy_versions?stage=retired']")
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
      |> form("#api-token-form", %{
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
      |> form("#api-token-form", %{
        "api_token" => %{"label" => "", "scopes" => ["strategies:read"]}
      })
      |> render_submit()

    assert html =~ "Give the token a label"
  end

  # Regression, 2026-09-25: phx-change re-renders the form on every click,
  # and the checkboxes had no `checked` binding, so ticking a second scope
  # cleared the first -- it behaved like single-select.
  test "ticking several scopes keeps all of them checked", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#api-token-form",
      api_token: %{
        "label" => "trading_live",
        "scopes" => ["strategies:read", "strategies:write", "target_pools:read"]
      }
    )
    |> render_change()

    for scope <- ["strategies:read", "strategies:write", "target_pools:read"] do
      assert has_element?(view, "#api-token-form input[value='#{scope}'][checked]")
    end

    refute has_element?(view, "#api-token-form input[value='tags:write'][checked]")
  end

  test "rejects no scopes selected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    html =
      view
      |> form("#api-token-form", %{"api_token" => %{"label" => "no-scopes", "scopes" => []}})
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

  describe "tags" do
    test "renders the tags section", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ "Tags"
    end

    test "creating a tag adds it to the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("form[phx-submit=create_tag]", %{"tag_name" => "needs-review"})
        |> render_submit()

      assert html =~ "needs-review"
      assert Enum.any?(Sim.list_tags(), &(&1.name == "needs-review"))
    end

    test "blank tag name is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("form[phx-submit=create_tag]", %{"tag_name" => "   "})
      |> render_submit()

      assert Sim.list_tags() == []
    end

    test "deleting a tag removes it from the list", %{conn: conn} do
      {:ok, tag} = Sim.get_or_create_tag("doomed")

      {:ok, view, html} = live(conn, ~p"/settings")
      assert html =~ "doomed"

      html =
        view
        |> element("button[phx-click=delete_tag][phx-value-id='#{tag.id}']")
        |> render_click()

      refute html =~ "doomed"
      assert Sim.list_tags() == []
    end
  end
end
