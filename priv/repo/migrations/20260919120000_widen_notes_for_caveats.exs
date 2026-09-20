defmodule TradingOptionsSim.Repo.Migrations.WidenNotesForCaveats do
  use Ecto.Migration

  # `add :notes, :string` in the original create migrations defaults to
  # varchar(255) in Ecto, which was never a deliberate ceiling — it is
  # just what :string means. It became a real constraint the moment
  # notes had to carry a structured caveat block
  # (TradingOptionsSim.Sim.Caveat): a single caveat entry explaining why
  # a run population is not comparable runs to several hundred
  # characters on its own, and a row can carry more than one.
  #
  # Worth noting what the old limit had already done silently: the
  # longest note in this table was 195 characters and the average 166,
  # which reads like a house style but is actually authors writing up
  # against a wall they could not see. The facts that ended up in git
  # commit messages instead of notes are exactly the ones a consumer
  # cannot query.
  #
  # :text rather than a larger varchar — Postgres stores them
  # identically and :text carries no number anyone has to justify later.
  def up do
    alter table(:strategy_versions) do
      modify :notes, :text
    end

    alter table(:strategies) do
      modify :notes, :text
    end
  end

  # Irreversible in practice: any note longer than 255 characters would
  # be truncated, and those are precisely the caveated ones this widening
  # exists to allow. Failing loudly beats silently discarding a caveat.
  def down do
    raise Ecto.MigrationError,
      message:
        "Cannot narrow notes back to varchar(255) without truncating caveat blocks. " <>
          "Shorten or clear the affected notes by hand first, then drop this migration."
  end
end
