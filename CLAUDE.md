# CLAUDE.md — trading_options_sim

This file scopes to `trading_options_sim` only and overrides the
workspace-level `../CLAUDE.md` git-workflow section **for this app**.
Every other sibling app in this workspace keeps the branch-per-task,
no-direct-main-commits, no-unsolicited-PR workflow described there
unchanged.

## Git workflow override (this app only)

- Commit directly to `main`. No feature branch required per task.
- `git push origin main` is pre-approved — push after committing without
  asking again first, the same way the rest of this file's instructions
  are followed without re-confirmation.
- Opening a PR is allowed when it's the right vehicle for a piece of
  work (e.g. a change the user wants reviewed before merging elsewhere),
  but is not required for ordinary commits to this repo.
- **Never merge a PR unless the user gives its PR number explicitly in
  the same request.** "Merge that" or "go ahead" without a number is not
  enough — ask which PR if it's ambiguous. This applies even if Claude
  itself opened the PR earlier in the same session.
- Still never force-push, rewrite history, or use `--no-verify` /
  `--no-gpg-sign` unless explicitly asked — this override is scoped to
  "commit and push to main directly," not a blanket relaxation of every
  other git safety practice in the workspace-level file.
- Still confirm before genuinely destructive actions (discarding
  uncommitted work, deleting branches/tags, resetting shared history).

## Note on tool-level approval

This file controls *instructed* behavior — it tells Claude to push
without asking again. It does not and cannot change Claude Code's own
runtime permission system: a `git push`/PR-creation call may still
prompt for approval or be blocked by the harness's own safety
classifier independent of anything written here. If that happens, it's
a tool-permission setting the user configures outside this file (e.g.
an allowlist rule in `.claude/settings.local.json`), not something this
file can override.
