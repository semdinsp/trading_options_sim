defmodule TradingOptionsSimWeb.PageController do
  use TradingOptionsSimWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
