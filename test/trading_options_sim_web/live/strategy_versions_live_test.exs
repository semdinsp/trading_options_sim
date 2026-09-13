defmodule TradingOptionsSimWeb.StrategyVersionsLiveTest do
  use TradingOptionsSimWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias TradingOptionsSim.Sim

  defp strategy_fixture do
    {:ok, strategy} = Sim.create_strategy(%{name: "Test Strategy"})
    strategy
  end

  defp version_fixture(strategy, attrs \\ %{}) do
    {:ok, version} =
      Sim.create_strategy_version(
        strategy,
        Map.merge(%{version: 1, position_sizing: %{"method" => "fixed_qty", "qty" => 1}}, attrs)
      )

    version
  end

  test "lists every strategy version regardless of stage", %{conn: conn} do
    strategy = strategy_fixture()
    version_fixture(strategy)

    {:ok, _view, html} = live(conn, ~p"/strategy_versions")
    assert html =~ "Test Strategy"
  end

  test "filters by lifecycle stage, including retired", %{conn: conn} do
    strategy = strategy_fixture()
    discovery_version = version_fixture(strategy, %{version: 1})
    {:ok, retired_version} = Sim.downgrade_strategy_version(discovery_version, "retired")

    {:ok, view, html} = live(conn, ~p"/strategy_versions?stage=retired")

    assert html =~ "v1"
    assert has_element?(view, "span", "retired")
    assert retired_version.lifecycle_stage == "retired"
  end

  test "shows lifecycle badge per version", %{conn: conn} do
    strategy = strategy_fixture()
    version_fixture(strategy)

    {:ok, _view, html} = live(conn, ~p"/strategy_versions")
    assert html =~ "discovery"
  end

  describe "tagging" do
    test "toggling the tag control shows the add-tag form", %{conn: conn} do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      {:ok, view, _html} = live(conn, ~p"/strategy_versions")

      html =
        view
        |> element("button[phx-click=toggle_tag_control][phx-value-id='#{version.id}']")
        |> render_click()

      assert html =~ "add tag"
    end

    test "adding a tag shows the chip", %{conn: conn} do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      {:ok, view, _html} = live(conn, ~p"/strategy_versions")

      view
      |> element("button[phx-click=toggle_tag_control][phx-value-id='#{version.id}']")
      |> render_click()

      html =
        view
        |> form("form[phx-submit=add_tag]", %{"version_id" => version.id, "tag_name" => "hot"})
        |> render_submit()

      assert html =~ "hot"
    end

    test "removing a tag hides the chip", %{conn: conn} do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      {:ok, version} = Sim.add_tag_to_strategy_version_by_name(version, "hot")
      tag = hd(version.tags)

      {:ok, view, html} = live(conn, ~p"/strategy_versions")
      assert html =~ "hot"

      html =
        view
        |> element(
          "button[phx-click=remove_tag][phx-value-id='#{version.id}'][phx-value-tag_id='#{tag.id}']"
        )
        |> render_click()

      refute html =~ "hot"
    end
  end
end
