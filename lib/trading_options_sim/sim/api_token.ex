defmodule TradingOptionsSim.Sim.ApiToken do
  @moduledoc """
  A scoped, revocable Bearer token backing both `/api/v1` and this app's
  MCP server (`TradingOptionsSim.MCP.Server`) — one token type for both
  surfaces, per `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §4a. Ported from
  `TradingSystem.Trading.ApiToken` nearly verbatim (same hash convention:
  `:crypto.strong_rand_bytes/1` + SHA-256).

  The raw token is generated and returned exactly once, at creation time
  (see `generate/3`) — only its hash is ever persisted. There is no way
  to recover a lost raw token; revoke it and generate a new one.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias TradingOptionsSim.Repo

  @hash_algorithm :sha256
  @rand_size 32

  @scopes ~w(strategies:read strategies:write
             target_pools:read target_pools:write
             tags:read tags:write
             runs:read
             mcp:read mcp:write)

  @primary_key {:id, UUIDv7, autogenerate: true}

  schema "api_tokens" do
    field :label, :string
    field :token_hash, :binary
    field :scopes, {:array, :string}, default: []
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :last_used_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Every scope this token type recognizes."
  def scopes, do: @scopes

  @doc """
  Generates a new raw token + its `ApiToken` changeset, ready for
  `Repo.insert/1`. Returns `{raw_token, changeset}` — `raw_token` is a
  URL-safe string to hand to the caller once and never persisted; only
  its hash goes into the changeset.
  """
  @spec generate(String.t(), [String.t()], map()) :: {String.t(), Ecto.Changeset.t()}
  def generate(label, scopes, attrs \\ %{}) do
    raw = :crypto.strong_rand_bytes(@rand_size) |> Base.url_encode64(padding: false)
    hash = hash_token(raw)

    changeset =
      %__MODULE__{}
      |> changeset(
        Map.merge(attrs, %{"label" => label, "scopes" => scopes, "token_hash" => hash})
      )

    {raw, changeset}
  end

  def changeset(api_token, attrs) do
    api_token
    |> cast(attrs, [:label, :token_hash, :scopes, :expires_at, :revoked_at, :last_used_at])
    |> validate_required([:label, :token_hash, :scopes])
    |> validate_subset(:scopes, @scopes)
    |> unique_constraint(:token_hash)
  end

  @doc """
  Looks up the still-valid (not expired, not revoked) `ApiToken` for a
  raw Bearer token string, if any. Does not update `last_used_at` — the
  caller (the auth plug) does that separately.
  """
  @spec verify(String.t()) :: {:ok, t :: struct()} | :error
  def verify(raw_token) do
    hash = hash_token(raw_token)
    now = DateTime.utc_now()

    query =
      from t in __MODULE__,
        where: t.token_hash == ^hash,
        where: is_nil(t.revoked_at),
        where: is_nil(t.expires_at) or t.expires_at > ^now

    case Repo.one(query) do
      nil -> :error
      token -> {:ok, token}
    end
  end

  @doc "Every active (not revoked) token whose `scopes` intersects `scopes` at all. Newest first."
  @spec active_with_scope([String.t()]) :: [t :: struct()]
  def active_with_scope(scopes) when is_list(scopes) do
    query =
      from t in __MODULE__,
        where: is_nil(t.revoked_at),
        where: fragment("? && ?", t.scopes, ^scopes),
        order_by: [desc: t.inserted_at]

    Repo.all(query)
  end

  defp hash_token(raw_token) do
    case Base.url_decode64(raw_token, padding: false) do
      {:ok, decoded} -> :crypto.hash(@hash_algorithm, decoded)
      :error -> :crypto.hash(@hash_algorithm, raw_token)
    end
  end
end
