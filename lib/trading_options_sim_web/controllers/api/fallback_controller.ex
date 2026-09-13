defmodule TradingOptionsSimWeb.Api.FallbackController do
  use TradingOptionsSimWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"errors" => errors})
  end

  def call(conn, {:error, :invalid_transition}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"errors" => %{"lifecycle_stage" => ["invalid transition"]}})
  end

  def call(conn, {:error, :no_target_pool}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"errors" => %{"target_pool_id" => ["must be set before promoting to quarantine"]}})
  end

  def call(conn, {:error, :not_linked}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"errors" => %{"live_strategy_active" => ["version is not currently linked"]}})
  end

  def call(conn, {:error, reason}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"errors" => %{"detail" => inspect(reason)}})
  end
end
