<div align="center">
  <img src="assets/banner.png" alt="gw — git worktrees, simplified" width="100%"/>

  <p>
    <em>A tiny zsh helper that makes <a href="https://git-scm.com/docs/git-worktree">git worktrees</a> feel like switching tabs.</em>
  </p>

  <p>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"/></a>
    <img src="https://img.shields.io/badge/shell-zsh-89e051?logo=gnu-bash&logoColor=white" alt="zsh"/>
    <img src="https://img.shields.io/badge/git-2.31%2B-f05032?logo=git&logoColor=white" alt="git 2.31+"/>
  </p>
</div>

---

## Why

Worktrees let you check out multiple branches at once — perfect for hopping between a feature, a hotfix review, and an agent's branch without stashing or cloning. The native CLI is just a bit clunky for everyday use:

```bash
git worktree add ../somewhere-else feature-x
cd ../somewhere-else
# ...later...
cd /path/to/main
git worktree remove ../somewhere-else
git branch -d feature-x
```

`gw` collapses that to:

```bash
gw -b feature-x   # create + cd in
gw -d feature-x   # remove + delete branch
```

All worktrees live under `<repo>/.worktrees/<branch>`, gitignored locally. You spend less time managing paths and more time writing code.

## Install

Clone once into `~/.claude/skills/gw/` and you get both the zsh helper and the [Claude Code skill](#claude-code-skill) in one go:

```bash
git clone https://github.com/ohwhen/gw.git ~/.claude/skills/gw
echo 'source ~/.claude/skills/gw/gw.zsh' >> ~/.zshrc
source ~/.zshrc
```

If you don't use Claude Code, clone anywhere and source `gw.zsh` from there — only the path changes.

### Updating

```bash
cd ~/.claude/skills/gw && git pull
```

Then `source ~/.zshrc` (or open a new shell) to load the new version.

## Usage

| Command | What it does |
|---|---|
| `gw` | List all worktrees |
| `gw <branch>` | Check out an existing branch in a worktree, `cd` into it |
| `gw -b <branch> [<start>]` | Create a new branch (from `<start>`, default `HEAD`) + worktree, `cd` into it |
| `gw -d <branch>` | Remove worktree and delete branch (refuses if dirty or unmerged) |
| `gw -D <branch>` | Force-remove worktree and force-delete branch |
| `gw -r` | `cd` to the main worktree from anywhere in the repo |
| `gw --no-cow ...` | Create the worktree without cloning gitignored files |
| `gw -h`, `--help` | Show help |

Slashes in branch names get sanitized into the directory: `owen/foo` → `.worktrees/owen-foo`.

## How it works

- On first use in a repo, `gw` adds `.worktrees/` to `.git/info/exclude` (local-only — no committed change to the repo) and creates the directory.
- `gw <branch>` is idempotent. If the worktree already exists, it just `cd`s in.
- `-d` mirrors `git branch -d` semantics: refuses to delete unmerged branches or dirty worktrees. `-D` is the force variant.
- All operations run against the main repo via `git -C`, so it works correctly from inside any linked worktree too.

## Copy-on-write worktrees

A fresh worktree normally has no `node_modules`, `.env`, or build output, so you reinstall and rebuild from cold. When `gw` creates a worktree, it also clones the main worktree's gitignored files into it as copy-on-write clones. Clones share disk blocks with the originals until one side writes, so a multi-GB `node_modules` appears in milliseconds and takes no extra space.

| Platform | Filesystems |
|---|---|
| macOS | APFS (`cp -c`) |
| Linux | btrfs, XFS (`reflink=1`), bcachefs, ZFS 2.2+ (`cp --reflink=always`) |

On any other filesystem (ext4, tmpfs, HFS+, exFAT), `gw` skips the copy with a warning and gives you a plain worktree. Byte-copying gigabytes of build cache is exactly what this avoids.

What gets cloned:

- **Tracked files**: never. They come from a normal `git worktree add`, so the worktree matches the branch exactly.
- **Untracked files that aren't ignored**: never, so your in-progress scratch files stay put.
- **Gitignored files**: yes, from the main worktree, with modification times preserved so build tools don't rebuild them.
- **Never**: other VCS metadata (`.hg`, `.jj`, `.svn`, ...), other tools' worktree dirs (`.worktrees`, `.claude/worktrees`, `.conductor`, `.entire`), and nested git repos.
- **Not by default**: Python virtualenvs (`pyvenv.cfg`) and CMake build dirs (`CMakeCache.txt`). Both embed absolute paths, so a clone would keep running from or building into the main worktree.

To clone only some ignored paths, commit a `.worktreeinclude` file in gitignore syntax, the same file [worktrunk](https://worktrunk.dev/step/) and [Claude Code](https://code.claude.com/docs/en/worktrees) read. When it exists, only ignored paths that also match it are cloned, and it can opt virtualenvs back in:

```gitignore
# .worktreeinclude
node_modules/
.env
```

To turn cloning off, pass `--no-cow` for one worktree, or run `git config gw.cow false` (add `--global` for every repo).

Cloning carries `.env` and other local secrets into each worktree. They stay on the same disk, just as if you'd copied them by hand; list only what you want in `.worktreeinclude` if that matters.

## Tab completion

Tab completion is included and is context-aware:

- `gw <Tab>` — branches that already have worktrees first, then all other local branches
- `gw -d <Tab>` / `gw -D <Tab>` — only branches that have a worktree (so you don't accidentally delete a random branch)
- `gw -b <Tab>` — all local branches as a reference (so you can avoid name collisions and follow your existing prefix conventions)

Requires `compinit` to be active (it is by default in oh-my-zsh, prezto, and most modern setups).

## Example session

A typical day: you're working on a feature, a teammate's PR review comes in, then you go back and finish.

**1. Start a new feature.**

```console
$ cd ~/code/myproject

$ gw -b owen/login-redesign
added .worktrees/ to /Users/me/code/myproject/.git/info/exclude
Preparing worktree (new branch 'owen/login-redesign')
HEAD is now at a1b2c3d main: bump version

$ pwd
/Users/me/code/myproject/.worktrees/owen-login-redesign
```

You're already in the new worktree. First time in this repo, `gw` set up `.worktrees/` in your local exclude.

**2. Teammate pings you for a PR review. You don't want to lose your in-progress edits — just spin up another worktree.**

```console
$ gw -b sara/payments-fix origin/sara/payments-fix
Preparing worktree (new branch 'sara/payments-fix')
HEAD is now at d4e5f6a Add retry on Stripe 5xx

$ # ...read the diff, leave comments, run the tests...

$ gw                            # see everything you've got going
/Users/me/code/myproject                                       a1b2c3d [main]
/Users/me/code/myproject/.worktrees/owen-login-redesign        b9c0d1e [owen/login-redesign]
/Users/me/code/myproject/.worktrees/sara-payments-fix          d4e5f6a [sara/payments-fix]
```

**3. Hop back to your feature. Tab completion knows which branches have worktrees and ranks them first.**

```console
$ gw owen/<Tab>
owen/login-redesign  -- worktree
owen/old-experiment  -- branch

$ gw owen/login-redesign
$ pwd
/Users/me/code/myproject/.worktrees/owen-login-redesign
```

**4. Push, open the PR, get it merged. Time to clean up. You're still inside the worktree — `gw -d` handles that.**

```console
$ git push -u origin owen/login-redesign
$ # ...PR merged on GitHub...

$ git fetch --prune
$ pwd
/Users/me/code/myproject/.worktrees/owen-login-redesign

$ gw -d owen/login-redesign
Deleted branch owen/login-redesign (was b9c0d1e).

$ pwd                           # gw cd'd you back to root before deleting
/Users/me/code/myproject
```

**5. Drop the review worktree the same way.**

```console
$ gw -d sara/payments-fix
Deleted branch sara/payments-fix (was d4e5f6a).

$ gw
/Users/me/code/myproject  a1b2c3d [main]
```

Back to a clean slate. No `cd`s memorized, no orphaned branches.

## Requirements

- zsh
- git 2.31 or newer
- For copy-on-write clones: macOS on APFS, or Linux with GNU coreutils on btrfs, XFS, bcachefs or ZFS 2.2+

## Claude Code skill

This repo doubles as a [Claude Code skill](https://docs.claude.com/en/docs/claude-code/skills) — see [`SKILL.md`](SKILL.md). When you clone into `~/.claude/skills/gw/` (the [Install](#install) step above), Claude Code automatically picks up the skill. It teaches an agent the `.worktrees/` isolation pattern — when to use a worktree instead of stashing, the path conventions, and the raw `git worktree` commands to use in non-interactive contexts.

## License

[MIT](LICENSE)
