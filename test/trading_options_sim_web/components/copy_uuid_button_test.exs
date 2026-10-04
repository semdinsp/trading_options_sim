defmodule TradingOptionsSimWeb.CopyUuidButtonTest do
  use TradingOptionsSimWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias TradingOptionsSimWeb.CoreComponents

  # The hook itself runs in the browser; these pin the markup it needs.
  test "renders the value, the hook, and the elements its feedback toggles" do
    html =
      render_component(&CoreComponents.copy_uuid_button/1,
        id: "copy-x",
        value: "01a0eb43-3e15-79b7-9dac-2e13860d245f"
      )

    doc = LazyHTML.from_fragment(html)
    [button] = doc |> LazyHTML.query("button#copy-x") |> Enum.to_list()

    assert LazyHTML.attribute(button, "data-copy-value") == [
             "01a0eb43-3e15-79b7-9dac-2e13860d245f"
           ]

    assert LazyHTML.attribute(button, "phx-hook") == [
             "TradingOptionsSimWeb.CoreComponents.CopyUuidButton"
           ]

    icons = button |> LazyHTML.query("[data-copy-icon]") |> LazyHTML.attribute("data-copy-icon")
    assert icons == ["idle", "ok", "error"]

    # Only the clipboard icon shows until a copy settles.
    assert button |> LazyHTML.query("[data-copy-icon].hidden") |> Enum.count() == 2

    [status] = button |> LazyHTML.query("[data-copy-status]") |> Enum.to_list()
    assert LazyHTML.attribute(status, "aria-live") == ["polite"]
  end
end
