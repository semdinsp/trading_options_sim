defmodule TradingOptionsSimWeb.SettingsLiveDbBackupTest do
  # async: false — mutates Application.put_env(:trading_options_sim,
  # :backup_dir, ...) and TradingOptionsSim.DbBackup.Test's shared Agent,
  # both process-global state a concurrently-running test could race.
  use TradingOptionsSimWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "Database Backup" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "trading_options_sim_backup_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      previous = Application.get_env(:trading_options_sim, :backup_dir)
      Application.put_env(:trading_options_sim, :backup_dir, dir)
      TradingOptionsSim.DbBackup.Test.reset()

      on_exit(fn ->
        File.rm_rf!(dir)

        if previous do
          Application.put_env(:trading_options_sim, :backup_dir, previous)
        else
          Application.delete_env(:trading_options_sim, :backup_dir)
        end
      end)

      %{dir: dir}
    end

    defp database_name, do: Keyword.fetch!(TradingOptionsSim.Repo.config(), :database)

    defp write_fake_backup(dir, filename_suffix, age_days) do
      filename = "#{database_name()}-#{filename_suffix}.pgdump"
      path = Path.join(dir, filename)
      File.write!(path, "fake dump contents")

      mtime = DateTime.utc_now() |> DateTime.add(-age_days, :day) |> DateTime.to_unix()
      File.touch!(path, mtime)

      path
    end

    test "shows no-backup state when the directory is empty", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/settings")

      assert html =~ "No backup found yet"
    end

    test "shows the most recent backup's timestamp and size", %{conn: conn, dir: dir} do
      write_fake_backup(dir, "20260101000000", 45)
      write_fake_backup(dir, "20260201000000", 10)

      {:ok, _live, html} = live(conn, ~p"/settings")

      assert html =~ "20260201000000"
      refute html =~ "20260101000000.pgdump"
      assert html =~ "B"
    end

    test "the reminder banner shows when the last backup is over 30 days old", %{
      conn: conn,
      dir: dir
    } do
      write_fake_backup(dir, "20260101000000", 45)

      {:ok, _live, html} = live(conn, ~p"/settings")

      assert html =~ "been over a month since your last database backup"
    end

    test "the reminder banner does not show when the last backup is recent", %{
      conn: conn,
      dir: dir
    } do
      write_fake_backup(dir, "20260101000000", 5)

      {:ok, _live, html} = live(conn, ~p"/settings")

      refute html =~ "been over a month since your last database backup"
    end

    test "dismissing the reminder hides it for the rest of the session", %{conn: conn, dir: dir} do
      write_fake_backup(dir, "20260101000000", 45)

      {:ok, live, html} = live(conn, ~p"/settings")
      assert html =~ "been over a month"

      html = live |> element("#backup-reminder-banner button") |> render_click()
      refute html =~ "been over a month"
    end

    test "clicking Back up now triggers the async dump and shows success", %{conn: conn} do
      TradingOptionsSim.DbBackup.Test.stub_dump(
        {:ok, "/fake/path/trading_options_sim_dev-20260907.pgdump"}
      )

      {:ok, live, _html} = live(conn, ~p"/settings")

      html = live |> element("button", "Back up database now") |> render_click()
      assert html =~ "Backing up…" or html =~ "Backup complete"

      html = render_async(live)
      assert html =~ "Backup complete"
      assert html =~ "trading_options_sim_dev-20260907.pgdump"
    end

    test "a pg_dump_not_found error renders the reason", %{conn: conn} do
      TradingOptionsSim.DbBackup.Test.stub_dump({:error, {:pg_dump_not_found, "pg_dump"}})

      {:ok, live, _html} = live(conn, ~p"/settings")

      live |> element("button", "Back up database now") |> render_click()
      html = render_async(live)

      assert html =~ "pg_dump not found"
    end

    test "a pg_dump_failed error renders the exit status", %{conn: conn} do
      TradingOptionsSim.DbBackup.Test.stub_dump(
        {:error, {:pg_dump_failed, 1, "connection refused"}}
      )

      {:ok, live, _html} = live(conn, ~p"/settings")

      live |> element("button", "Back up database now") |> render_click()
      html = render_async(live)

      assert html =~ "exited 1"
      assert html =~ "connection refused"
    end

    test "a pg_dump_timeout error renders the timeout", %{conn: conn} do
      TradingOptionsSim.DbBackup.Test.stub_dump({:error, {:pg_dump_timeout, 300_000}})

      {:ok, live, _html} = live(conn, ~p"/settings")

      live |> element("button", "Back up database now") |> render_click()
      html = render_async(live)

      assert html =~ "did not finish within 300s"
    end

    test "the button is disabled while the backup is running", %{conn: conn} do
      TradingOptionsSim.DbBackup.Test.stub_dump({:ok, "/fake/path/x.pgdump"})

      {:ok, live, _html} = live(conn, ~p"/settings")

      html = live |> element("button", "Back up database now") |> render_click()
      assert html =~ "disabled"

      render_async(live)
    end
  end
end
