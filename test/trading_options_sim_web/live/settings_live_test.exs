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
