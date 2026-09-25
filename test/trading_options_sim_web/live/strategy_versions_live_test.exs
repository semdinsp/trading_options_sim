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

  test "the default (All) view excludes retired versions", %{conn: conn} do
    strategy = strategy_fixture()
    _discovery_version = version_fixture(strategy, %{version: 1})
    retired_version = version_fixture(strategy, %{version: 2})
    {:ok, _retired} = Sim.downgrade_strategy_version(retired_version, "retired")

    {:ok, view, _html} = live(conn, ~p"/strategy_versions")

    # Scoped to the version headings. The whole-page HTML also carries
    # random base64 tokens (the LiveView session, CSRF), and a bare
    # `refute html =~ "v2"` failed whenever one happened to contain "v2"
    # -- measured at 2 renders in 300 (e.g. "...CIv2Tpeg...").
    assert has_element?(view, "h2", "v1")
    refute has_element?(view, "h2", "v2")
    assert Sim.get_strategy_version!(retired_version.id).lifecycle_stage == "retired"
  end

  test "the explicit Retired filter still shows retired versions", %{conn: conn} do
    strategy = strategy_fixture()
    version = version_fixture(strategy)
    {:ok, _retired} = Sim.downgrade_strategy_version(version, "retired")

    {:ok, _view, html} = live(conn, ~p"/strategy_versions?stage=retired")

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

  test "shows the stage counts strip, unaffected by the current stage filter", %{conn: conn} do
    strategy = strategy_fixture()
    discovery_version = version_fixture(strategy, %{version: 1})
    version_fixture(strategy, %{version: 2})
    {:ok, _retired} = Sim.downgrade_strategy_version(discovery_version, "retired")

    {:ok, _view, html} = live(conn, ~p"/strategy_versions?stage=retired")

    # One retired, one still discovery — the strip counts both stages
    # even though the page itself is filtered to only show "retired".
    assert html =~ "D 1"
    assert html =~ "R 1"
  end

  describe "retire/unretire" do
    test "retiring a version drops it from the default (All) view — retired is opt-in", %{
      conn: conn
    } do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      {:ok, view, _html} = live(conn, ~p"/strategy_versions")
      assert has_element?(view, "button[phx-click=retire][phx-value-id='#{version.id}']")
      refute has_element?(view, "button[phx-click=unretire][phx-value-id='#{version.id}']")

      view
      |> element("button[phx-click=retire][phx-value-id='#{version.id}']")
      |> render_click()

      assert Sim.get_strategy_version!(version.id).lifecycle_stage == "retired"
      # Retired now, so it's gone from the default "All" view — retired
      # versions are opt-in via the explicit "Retired" filter button.
      refute has_element?(view, "button[phx-click=unretire][phx-value-id='#{version.id}']")
      refute has_element?(view, "h2", "Test Strategy")

      {:ok, view, _html} = live(conn, ~p"/strategy_versions?stage=retired")
      assert has_element?(view, "button[phx-click=unretire][phx-value-id='#{version.id}']")
    end

    test "unretiring a version puts it back in discovery", %{conn: conn} do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      {:ok, version} = Sim.downgrade_strategy_version(version, "retired")

      {:ok, view, _html} = live(conn, ~p"/strategy_versions?stage=retired")
      assert has_element?(view, "button[phx-click=unretire][phx-value-id='#{version.id}']")

      view
      |> element("button[phx-click=unretire][phx-value-id='#{version.id}']")
      |> render_click()

      assert Sim.get_strategy_version!(version.id).lifecycle_stage == "discovery"
    end
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

  describe "trading hours settings" do
    test "shows the default trading hours policy and overnight hold state", %{conn: conn} do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      {:ok, _view, html} = live(conn, ~p"/strategy_versions")

      assert html =~ "Regular Hours Only"
      assert html =~ "Overnight Hold: Off"
      refute version.overnight_hold
    end

    test "changing the trading hours policy dropdown persists the choice", %{conn: conn} do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      {:ok, view, _html} = live(conn, ~p"/strategy_versions")

      view
      |> form("#trading-hours-form-#{version.id}", %{"policy" => "unrestricted"})
      |> render_change()

      assert Sim.get_strategy_version!(version.id).trading_hours_policy == "unrestricted"
    end

    test "toggling overnight hold flips it on then off", %{conn: conn} do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      {:ok, view, html} = live(conn, ~p"/strategy_versions")
      assert html =~ "Overnight Hold: Off"

      html =
        view
        |> element("button[phx-click=toggle_overnight_hold][phx-value-id='#{version.id}']")
        |> render_click()

      assert html =~ "Overnight Hold: On"
      assert Sim.get_strategy_version!(version.id).overnight_hold == true

      html =
        view
        |> element("button[phx-click=toggle_overnight_hold][phx-value-id='#{version.id}']")
        |> render_click()

      assert html =~ "Overnight Hold: Off"
      assert Sim.get_strategy_version!(version.id).overnight_hold == false
    end
  end
end
