defmodule TradingOptionsSimWeb.Api.TagController do
  use TradingOptionsSimWeb, :controller

  alias TradingOptionsSim.Sim
  alias TradingOptionsSimWeb.Api.Serializer

  plug TradingOptionsSimWeb.ApiAuthPlug, scope: "tags:read"

  def index(conn, _params) do
    tags = Sim.list_tags() |> Enum.map(&Serializer.tag/1)
    json(conn, %{"tags" => tags})
  end
end
