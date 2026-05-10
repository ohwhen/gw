---
name: gw
description: Use the gw helper (a zsh function shipped at ~/.claude/skills/gw/gw.zsh) to do parallel, isolated, or experimental work in a git repo via worktrees under .worktrees/<branch>. Load when about to stash uncommitted work to switch branches, when starting throwaway/experimental work, when running a long build/test on one branch while editing another, when reviewing a teammate's PR without disturbing in-progress edits, or whenever the task benefits from an isolated checkout that can be discarded cleanly.
---

# gw — git worktree pattern

`gw` is a zsh helper that creates worktrees under `<repo>/.worktrees/<sanitized-branch>` and gitignores them via `.git/info/exclude` (local-only). **Always prefer `gw` over raw `git worktree`** — it handles the path convention, the ignore setup, and the safe-escape-on-delete behavior automatically. Raw `git worktree` should only be a fallback if `gw` is genuinely unavailable.

## When to use

- The user has uncommitted edits and asks you to switch to a different branch — create a worktree instead of stashing.
- You're starting experimental work that may be thrown away.
- You want to run a long build/test on one branch while continuing to edit another.
- Multiple agents or tasks need isolated copies of the same repo.
- A teammate's PR needs review without losing your in-progress work.

## Commands

```bash
gw                       # list all worktrees in this repo
gw <branch>              # check out existing branch in .worktrees/<branch>, cd in
gw -b <branch>           # create new branch + worktree, cd in
gw -d <branch>           # remove worktree + delete branch (safe; refuses if dirty/unmerged)
gw -D <branch>           # force-remove worktree + force-delete branch
gw -r                    # cd back to the main worktree
gw -h                    # show help
```

Slashes in branch names are sanitized into the directory: `owen/foo` → `.worktrees/owen-foo`.

## How to invoke from an agent shell

`gw` is a zsh function, not a binary, so a plain `bash -c gw …` will not find it. From any non-zsh shell (Bash tool, scripts, CI), invoke via zsh and source the file:

```bash
zsh -c 'source ~/.claude/skills/gw/gw.zsh && gw -b owen/feature'
```

The worktree's filesystem path is deterministic — the `cd` inside `gw` doesn't persist back to the agent shell, but you don't need it to. After the call returns, the worktree exists at `<repo-root>/.worktrees/<sanitized-branch>` and you can pass that path to subsequent `Read`/`Write`/`Bash` calls.

To find `<repo-root>` for path construction:

```bash
git rev-parse --path-format=absolute --git-common-dir | xargs dirname
```

## Fallback (only if gw is unavailable)

If `~/.claude/skills/gw/gw.zsh` doesn't exist on the machine, fall back to raw `git worktree` while keeping the same conventions:

```bash
grep -qxF .worktrees/ .git/info/exclude || echo .worktrees/ >> .git/info/exclude
mkdir -p .worktrees
git worktree add -b owen/feature .worktrees/owen-feature
# ...later...
git worktree remove .worktrees/owen-feature
git branch -d owen/feature
```

## Pitfalls

- A branch can only be checked out in one worktree at a time. Use `git worktree add --detach <path> <ref>` if you only need the commits.
- `gw -d` from inside the target worktree is safe — it `cd`s to the main worktree first. Raw `git worktree remove` does not, so you'd be left in a deleted directory.
- `gw -D` (and `git worktree remove --force`) discard uncommitted changes silently.
- Do not put worktrees inside a path Git already tracks; gitignore cannot override an already-tracked file. `.worktrees/` at the repo root is safe.
- Each worktree gets its own untracked files (`node_modules`, `.env`, build outputs). The `.git` database, branches, and stashes are shared.
- Run `git worktree prune` if a worktree directory was deleted by hand (`rm -rf`) instead of via `gw -d` / `git worktree remove`.
